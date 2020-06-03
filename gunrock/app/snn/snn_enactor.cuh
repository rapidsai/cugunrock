// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * snn_enactor.cuh
 *
 * @brief snn Problem Enactor
 */

#pragma once

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/enactor_iteration.cuh>
#include <gunrock/app/enactor_loop.cuh>
#include <gunrock/oprtr/oprtr.cuh>

#include <gunrock/app/snn/snn_problem.cuh>
#include <gunrock/app/snn/snn_helpers.cuh>
#include <gunrock/util/scan_device.cuh>
#include <gunrock/util/sort_device.cuh>

#include <gunrock/oprtr/1D_oprtr/for.cuh>
#include <gunrock/oprtr/oprtr.cuh>

//KNN app
#include <gunrock/app/knn/knn_enactor.cuh>
#include <gunrock/app/knn/knn_test.cuh>

//#define SNN_DEBUG 1

#ifdef SNN_DEBUG
    #define debug(a...) printf(a)
#else
    #define debug(a...)
#endif

namespace gunrock {
namespace app {
namespace snn {

/**
 * @brief Speciflying parameters for snn Enactor
 * @param parameters The util::Parameter<...> structure holding all parameter
 * info \return cudaError_t error message(s), if any
 */
cudaError_t UseParameters_enactor(util::Parameters &parameters) {
  cudaError_t retval = cudaSuccess;
  GUARD_CU(app::UseParameters_enactor(parameters));

  return retval;
}

/**
 * @brief defination of snn iteration loop
 * @tparam EnactorT Type of enactor
 */
template <typename EnactorT>
struct snnIterationLoop : public IterationLoopBase<EnactorT, Use_FullQ | Push> {
  typedef typename EnactorT::VertexT VertexT;
  typedef typename EnactorT::SizeT SizeT;
  typedef typename EnactorT::ValueT ValueT;
  typedef typename EnactorT::Problem::GraphT::CsrT CsrT;
  typedef typename EnactorT::Problem::GraphT::GpT GpT;

  typedef IterationLoopBase<EnactorT, Use_FullQ | Push> BaseIterationLoop;

  snnIterationLoop() : BaseIterationLoop() {}

  /**
   * @brief Core computation of knn, one iteration
   * @param[in] peer_ Which GPU peers to work on, 0 means local
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Core(int peer_ = 0) {
    // --
    // Alias variables

    auto &data_slice = this->enactor->problem->data_slices[this->gpu_num][0];

    auto &enactor_slice =
        this->enactor
            ->enactor_slices[this->gpu_num * this->enactor->num_gpus + peer_];

    auto &enactor_stats = enactor_slice.enactor_stats;
    auto &frontier = enactor_slice.frontier;
    auto &oprtr_parameters = enactor_slice.oprtr_parameters;
    auto &retval = enactor_stats.retval;
    auto &iteration = enactor_stats.iteration;
    auto num_points = data_slice.num_points;

    // K-Nearest Neighbors data
    auto &knns = data_slice.knns;

    // Number of KNNs
    auto k = data_slice.k;
    // Parameter of density
    auto eps = data_slice.eps;
    // Parameter of core point
    auto min_pts = data_slice.min_pts;

    // Shared Nearest Neighbors
    auto &snn_density = data_slice.snn_density;
    auto &cluster_id = data_slice.cluster_id;
    auto &core_points = data_slice.core_points;
    auto &core_points_counter = data_slice.core_points_counter;
    auto &core_point_mark_0 = data_slice.core_point_mark_0;
    auto &core_point_mark = data_slice.core_point_mark;

    // CUB Related storage
    auto &cub_temp_storage = data_slice.cub_temp_storage;
    auto &offsets = data_slice.offsets;
    auto &knns_sorted = data_slice.knns_out;

    cudaStream_t stream = oprtr_parameters.stream;
    auto target = util::DEVICE;
    util::Array1D<SizeT, VertexT> *null_frontier = NULL;
    oprtr_parameters.advance_mode = "ALL_EDGES";

#ifdef SNN_DEBUG
    // DEBUG ONLY
      GUARD_CU(knns.ForAll(
          [num_points, k] 
          __host__ __device__(SizeT * knns_, const SizeT &pos) {
          debug("[knn_enactor] knn:\n");
          for (int i=0; i<num_points; ++i){
            debug("knn[%d]: ", i);
            for (int j=0; j<k; ++j){
                debug("%d ", knns_[i*k+j]);
            }
            debug("\n");
          }
          }, 1, target, stream));
#endif

    // Sort all the knns using CUB
    GUARD_CU(util::SegmentedSort(knns, knns_sorted, num_points*k,
                num_points, offsets));
    GUARD_CU2(cudaDeviceSynchronize(), "cudaDeviceSynchronize failed.");

#ifdef SNN_DEBUG
    // DEBUG ONLY
      GUARD_CU(knns_sorted.ForAll(
          [num_points, k] 
          __host__ __device__(SizeT * knns_, const SizeT &pos) {
          debug("[knn_enactor] knn:\n");
          for (int i=0; i<num_points; ++i){
            debug("knn[%d]: ", i);
            for (int j=0; j<k; ++j){
                debug("%d ", knns_[i*k+j]);
            }
            debug("\n");
          }
          }, 1, target, stream));
#endif
          
    // SNN density of each point
    auto density_op = 
        [num_points, k, eps, min_pts, knns_sorted, snn_density]
        __host__ __device__ (VertexT *v, const SizeT &pos){
     //     for (int pos = 0; pos < k*num_points; ++pos){ //uncomment for debug
          auto x = pos/k;
          auto q = knns_sorted[x * k + (pos%k)];
          //   continue;
          // Checking SNN similarity
          // knns are sorted, counting intersection of knns[x] and knns[q]
          
          #pragma unroll  // all iterations are independent
          for (int i = 0; i < k; ++i){
            if (knns_sorted[q * k + i] == x){
              auto similarity = SNNsimilarity(x, q, knns_sorted, eps, k);
              if (similarity >= eps){
                  // x and q are SNN
                  atomicAdd(&snn_density[x], 1);
              }
              break;
            }
          }
    //      }       //uncomment for debug
        };
    // Find density of each point
    GUARD_CU(frontier.V_Q()->ForAll(density_op, num_points*k, target, stream));
    //uncomment for debug
    //GUARD_CU(frontier.V_Q()->ForAll(density_op, 1, target, stream)); 
 
/*    auto intersect_op =
        [num_points, k, eps, min_pts, knns_sorted, snn_density]
        __host__ __device__ (VertexT *v, const VertexT* edge){
          atomicAdd(&snn_density[x], 1);
        };*/

#ifdef SNN_DEBUG
    // DEBUG ONLY: write down densities:
    GUARD_CU(snn_density.ForAll(
        [num_points, k]
        __host__ __device__ (SizeT* sd, const SizeT &pos){
          debug("snn densities: \n");
          for (int i=0; i<num_points; ++i){
            debug("density[%d] = %d\n", i, sd[i]);
          }
        }, 1, target, stream));
#endif
         
    // Mark core points
    GUARD_CU(core_point_mark_0.ForAll(
        [snn_density, min_pts] 
        __host__ __device__(SizeT* cp, const SizeT &pos) {
          if (snn_density[pos] >= min_pts) {
            cp[pos] = 1;
          }
        }, num_points, target, stream));

    GUARD_CU(util::cubInclusiveSum(cub_temp_storage, core_point_mark_0,
                                     core_point_mark, num_points, stream));

    GUARD_CU(core_points.ForAll(
        [num_points, core_point_mark, core_points_counter] 
        __host__ __device__(SizeT * cps, const SizeT &pos) {
          if ((pos == 0 && core_point_mark[pos] != 0) ||
            (pos > 0 && core_point_mark[pos] != core_point_mark[pos - 1])) {
            cps[core_point_mark[pos] - 1] = pos;
            //printf("%d core point go to %d\n", pos, core_point_mark[pos] - 1);
          }
          if (pos == num_points - 1) 
            core_points_counter[0] = core_point_mark[pos];
        }, num_points, target, stream));

#ifdef SNN_DEBUG
    // DEBUG ONLY: write down core points
    GUARD_CU(core_point_mark_0.ForAll(
        [core_points_counter, core_points]
        __host__ __device__ (SizeT* cp, const SizeT &pos){
          SizeT cpc = core_points_counter[0];
          debug("core pointes: \n");
          for (int i=0; i<cpc; ++i){
            debug("%d ", core_points[i]);
          }
          debug("\n");
        }, 1, target, stream));
#endif

    // Core points merging
    auto merging_op = 
        [num_points, eps, k, core_point_mark, core_points, core_points_counter,
        knns_sorted, cluster_id]
        __host__ __device__ (const int &cos, const SizeT &pos){
          // x core point
          auto x = core_points[pos/k];
          auto q = knns_sorted[x * k + (pos%k)];
          // q is k nearest neighbor of x and ...
          if (x <= q)
            return;
          if ((q == 0 && core_point_mark[q] != 1) || 
            (q > 0 && core_point_mark[q] == core_point_mark[q-1])){
            // ... q is non core point
            return;
          }
          // then if 
          for (int i = 0; i < k; ++i){
            if (knns_sorted[q * k + i] == x){
              // x is k nearest neighbor of q as well then ...
              auto SNNsm = SNNsimilarity(x, q, knns_sorted, eps, k);
              debug("%d and %d share %d neighbors\n", x, q, SNNsm);
              if (SNNsm >= eps){
                // ... if x and q are shared nearest neighbors then merge them
                auto cluster_id_x = cluster_id[x];
                if (!util::isValid(cluster_id_x))
                    cluster_id_x = x;
                auto cluster_id_q = cluster_id[q];
                if (!util::isValid(cluster_id_q))
                    cluster_id_q = q;
                auto cluster_min = min(cluster_id_x, cluster_id_q);
                atomicMin(cluster_id + x, cluster_min);
                atomicMin(cluster_id + q, cluster_min);
              }
              break;
            }
          }
        };

     GUARD_CU(core_points_counter.Move(util::DEVICE, util::HOST, 1, 0, stream));
     GUARD_CU2(cudaStreamSynchronize(stream), "cudaStreamSynchronize failed");
     
     printf("GPU number of core points found: %d\n", core_points_counter[0]);

     // Assign core points to clusters
     SizeT loop_size = core_points_counter[0] * k;
     SizeT num_repeats = log2(core_points_counter[0]);
     gunrock::oprtr::RepeatFor(
         merging_op, num_repeats, loop_size, util::DEVICE, stream,
         util::PreDefinedValues<int>::InvalidValue,  // grid_size
         util::PreDefinedValues<int>::InvalidValue,  // block_size
         2);
     
     // Assign other non-core and non-noise points to clusters
     auto clustering_op = 
        [core_point_mark, eps, k, cluster_id, min_pts, knns_sorted] 
        __host__ __device__(VertexT * v_q, const SizeT &src) {
          // only non-core points
          if ((src == 0 && core_point_mark[src] == 1) || 
            (src > 0 && core_point_mark[src - 1] != core_point_mark[src])) 
            return;
          SizeT counterMax = 0;
          SizeT max_y = util::PreDefinedValues<SizeT>::InvalidValue;;
          for (int i = 0; i < k; ++i){
            SizeT y = knns_sorted[src * k + i];
            if ((y == 0 && core_point_mark[y] == 1) || 
              (y > 0 && core_point_mark[y - 1] != core_point_mark[y])){
              SizeT res = SNNsimilarity(src, y, knns_sorted, eps, k, false);
              if (!util::isValid(max_y) || res > counterMax){
                counterMax = res;
                max_y = y;
              }
            }
          }
          // only non-noise points
          if (util::isValid(max_y) && counterMax >= eps){
            auto c_id = cluster_id[max_y];
            if (!util::isValid(c_id))
                c_id = max_y;
            cluster_id[src] = c_id;
          }else{
            cluster_id[src] = util::PreDefinedValues<SizeT>::InvalidValue;
          }
        };

     // Assign other non-core and non-noise points to clusters
     GUARD_CU(frontier.V_Q()->ForAll(clustering_op, num_points, target, stream));

#ifdef SNN_DEBUG
     // DEBUG ONLY: write down densities:
    GUARD_CU(cluster_id.ForAll(
        [num_points, k]
        __host__ __device__ (SizeT* c_id, const SizeT &pos){
          debug("clusters: \n");
          for (int i=0; i<num_points; ++i){
            debug("cluster[%d] = %d\n", i, c_id[i]);
          }
        }, 1, target, stream));
#endif
    
     GUARD_CU(frontier.work_progress.GetQueueLength(
        frontier.queue_index, frontier.queue_length, false, stream, true));

     return retval;
  }

  /**
   * @brief Routine to combine received data and local data
   * @tparam NUM_VERTEX_ASSOCIATES Number of data associated with each
   * transmition item, typed VertexT
   * @tparam NUM_VALUE__ASSOCIATES Number of data associated with each
   * transmition item, typed ValueT
   * @param  received_length The numver of transmition items received
   * @param[in] peer_ which peer GPU the data came from
   * \return cudaError_t error message(s), if any
   */
  template <int NUM_VERTEX_ASSOCIATES, int NUM_VALUE__ASSOCIATES>
  cudaError_t ExpandIncoming(SizeT &received_length, int peer_) {
    // ================ INCOMPLETE TEMPLATE - MULTIGPU ====================

    auto &data_slice = this->enactor->problem->data_slices[this->gpu_num][0];
    auto &enactor_slice =
        this->enactor
            ->enactor_slices[this->gpu_num * this->enactor->num_gpus + peer_];
    // auto iteration = enactor_slice.enactor_stats.iteration;

    auto expand_op = [
                         // TODO: pass data used by the lambda, e.g.:
    ] __host__ __device__(VertexT & key, const SizeT &in_pos,
                          VertexT *vertex_associate_ins,
                          ValueT *value__associate_ins) -> bool {
      return true;
    };

    cudaError_t retval =
        BaseIterationLoop::template ExpandIncomingBase<NUM_VERTEX_ASSOCIATES,
                                                       NUM_VALUE__ASSOCIATES>(
            received_length, peer_, expand_op);
    return retval;
  }

  bool Stop_Condition(int gpu_num = 0) {
    auto it = this->enactor->enactor_slices[0].enactor_stats.iteration;
    if (it > 0)
      return true;
    else
      return false;
  }
};  // end of snnIteration

/**
 * @brief snn enactor class.
 * @tparam _Problem Problem type we process on
 * @tparam ARRAY_FLAG Flags for util::Array1D used in the enactor
 * @tparam cudaHostRegisterFlag Flags for util::Array1D used in the enactor
 */
template <typename _Problem, util::ArrayFlag ARRAY_FLAG = util::ARRAY_NONE,
          unsigned int cudaHostRegisterFlag = cudaHostRegisterDefault>
class Enactor
    : public EnactorBase<
          typename _Problem::GraphT, typename _Problem::GraphT::VertexT,
          typename _Problem::GraphT::ValueT, ARRAY_FLAG, cudaHostRegisterFlag> {
 public:
  typedef _Problem Problem;
  typedef typename Problem::SizeT SizeT;
  typedef typename Problem::VertexT VertexT;
  typedef typename Problem::GraphT GraphT;
  typedef typename GraphT::VertexT LabelT;
  typedef typename GraphT::ValueT ValueT;
  typedef EnactorBase<GraphT, LabelT, ValueT, ARRAY_FLAG, cudaHostRegisterFlag>
      BaseEnactor;
  typedef Enactor<Problem, ARRAY_FLAG, cudaHostRegisterFlag> EnactorT;
  typedef snnIterationLoop<EnactorT> IterationT;

  Problem *problem;
  IterationT *iterations;

  /**
   * @brief snn constructor
   */
  Enactor() : BaseEnactor("SNN"), problem(NULL) {
    this->max_num_vertex_associates = 0;
    this->max_num_value__associates = 1;
  }

  /**
   * @brief snn destructor
   */
  virtual ~Enactor() { /*Release();*/
  }

  /*
   * @brief Releasing allocated memory space
   * @param target The location to release memory from
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Release(util::Location target = util::LOCATION_ALL) {
    cudaError_t retval = cudaSuccess;
    GUARD_CU(BaseEnactor::Release(target));
    delete[] iterations;
    iterations = NULL;
    problem = NULL;
    return retval;
  }

  /**
   * @brief Initialize the problem.
   * @param[in] problem The problem object.
   * @param[in] target Target location of data
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Init(Problem &problem, util::Location target = util::DEVICE) {
    cudaError_t retval = cudaSuccess;
    this->problem = &problem;
    SizeT num_points = problem.num_points;

    // Lazy initialization
    GUARD_CU(BaseEnactor::Init(problem, Enactor_None, 2, NULL, target, false));

    for (int gpu = 0; gpu < this->num_gpus; gpu++) {
      GUARD_CU(util::SetDevice(this->gpu_idx[gpu]));
      auto &enactor_slice = this->enactor_slices[gpu * this->num_gpus + 0];
      auto &graph = problem.sub_graphs[gpu];
      GUARD_CU(enactor_slice.frontier.Allocate(num_points, 
                  num_points*num_points, this->queue_factors));
    }

    iterations = new IterationT[this->num_gpus];
    for (int gpu = 0; gpu < this->num_gpus; gpu++) {
      GUARD_CU(iterations[gpu].Init(this, gpu));
    }

    GUARD_CU(this->Init_Threads(
        this, (CUT_THREADROUTINE) & (GunrockThread<EnactorT>)));
    return retval;
  }

  /**
   * @brief one run of snn, to be called within GunrockThread
   * @param thread_data Data for the CPU thread
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Run(ThreadSlice &thread_data) {
    gunrock::app::Iteration_Loop<
        // change to how many {VertexT, ValueT} data need to communicate
        //       per element in the inter-GPU sub-frontiers
        0, 1, IterationT>(thread_data, iterations[thread_data.thread_num]);
    return cudaSuccess;
  }

  /**
   * @brief Reset enactor
...
   * @param[in] target Target location of data
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Reset(util::Location target = util::DEVICE) {
    typedef typename GraphT::GpT GpT;
    cudaError_t retval = cudaSuccess;

    GUARD_CU(BaseEnactor::Reset(target));

    SizeT num_points = this->problem->data_slices[0][0].num_points;
                //this->problem->data_slices[0][0].sub_graph[0].num_points;

    for (int gpu = 0; gpu < this->num_gpus; gpu++) {
      if (this->num_gpus == 1) {
        this->thread_slices[gpu].init_size = num_points;
        for (int peer_ = 0; peer_ < this->num_gpus; peer_++) {
          auto &frontier =
              this->enactor_slices[gpu * this->num_gpus + peer_].frontier;
          frontier.queue_length = (peer_ == 0) ? num_points : 0;
          if (peer_ == 0) {
            util::Array1D<SizeT, VertexT> tmp;
            tmp.Allocate(num_points, target | util::HOST);
            for (SizeT i = 0; i < num_points; ++i) {
              tmp[i] = (VertexT)i % num_points;
            }
            GUARD_CU(tmp.Move(util::HOST, target));

            GUARD_CU(frontier.V_Q()->ForEach(
                tmp,
                [] __host__ __device__(VertexT & v, VertexT & i) { v = i; },
                num_points, target, 0));

            tmp.Release();
          }
        }
      } else {
        // MULTIGPU INCOMPLETE
      }
    }

    GUARD_CU(BaseEnactor::Sync());
    return retval;
  }

  /**
   * @brief Enacts a snn computing on the specified graph.
...
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Enact() {
    cudaError_t retval = cudaSuccess;
    GUARD_CU(this->Run_Threads(this));
    util::PrintMsg("GPU SNN Done.", this->flag & Debug);
    return retval;
  }
};

}  // namespace knn
}  // namespace app
}  // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
