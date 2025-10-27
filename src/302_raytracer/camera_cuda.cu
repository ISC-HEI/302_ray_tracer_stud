/**
 * @file camera_cuda.cu
 * @brief CUDA-accelerated ray tracing template
 */

#include <cfloat>
#include <cmath>
#include <cstdio>
#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <device_launch_parameters.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

//==============================================================================
// VECTOR MATH AND UTILITY STRUCTURES
//==============================================================================

/**
 * @brief Simple 3D vector structure optimized for CUDA
 * Provides basic vector operations for ray tracing computations
 */
struct float3_simple
{
   float x, y, z;
   __device__ __host__ float3_simple() : x(0), y(0), z(0) {}
   __device__ __host__ float3_simple(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}

   __device__ __host__ float3_simple operator+(const float3_simple &other) const
   {
      return float3_simple(x + other.x, y + other.y, z + other.z);
   }

   __device__ __host__ float3_simple operator-(const float3_simple &other) const
   {
      return float3_simple(x - other.x, y - other.y, z - other.z);
   }

   __device__ __host__ float3_simple operator*(float t) const { return float3_simple(x * t, y * t, z * t); }

   __device__ __host__ float3_simple operator/(float t) const { return float3_simple(x / t, y / t, z / t); }

   __device__ __host__ float3_simple operator-() const { return float3_simple(-x, -y, -z); }

   __device__ __host__ float length() const { return sqrtf(x * x + y * y + z * z); }

   __device__ __host__ float length_squared() const { return x * x + y * y + z * z; }
};

__device__ __host__ float3_simple operator*(float t, const float3_simple &v) { return v * t; }

/** @brief Compute dot product of two vectors */
__device__ __host__ float dot(const float3_simple &a, const float3_simple &b)
{
   return a.x * b.x + a.y * b.y + a.z * b.z;
}

/** @brief Compute cross product of two vectors */
__device__ __host__ float3_simple cross(const float3_simple &a, const float3_simple &b)
{
   return float3_simple(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

/** @brief Normalize a vector to unit length */
__device__ __host__ float3_simple unit_vector(const float3_simple &v) { return v / v.length(); }

//==============================================================================
// RAY TRACING DATA STRUCTURES AND FUNCTIONS
//==============================================================================

/**
 * @brief Simple ray structure for ray tracing calculations
 */
struct ray_simple
{
   float3_simple orig, dir; ///< Ray origin and direction

   __device__ __host__ ray_simple() {}
   __device__ __host__ ray_simple(const float3_simple &origin, const float3_simple &direction)
       : orig(origin), dir(direction)
   {
   }

   /** @brief Get point along ray at parameter t */
   __device__ __host__ float3_simple at(float t) const { return orig + t * dir; }
};

/** @brief Convert a normal to a debug RGB color */
__device__ __host__ inline float3_simple normal_to_color(const float3_simple &n)
{
   return float3_simple(0.5f * (n.x + 1.0f), 0.5f * (n.y + 1.0f), 0.5f * (n.z + 1.0f));
}

//==============================================================================
// RANDOM NUMBER GENERATION AND SAMPLING
//==============================================================================

/** @brief Generate random float in range [0,1) using CUDA's curand */
__device__ float random_float(curandState *state) { return curand_uniform(state); }

/** @brief Smooth interpolation function for gradual transitions */
__device__ float smoothstep(float edge0, float edge1, float x)
{
   float t = fmaxf(0.0f, fminf(1.0f, (x - edge0) / (edge1 - edge0)));
   return t * t * (3.0f - 2.0f * t);
}

//==============================================================================
// CUDA KERNELS
//==============================================================================

/**
 * @brief Initialize random states for all threads
 * This kernel should be called once at startup to initialize the shared random state array
 * @param rand_states Array of random states (one per thread/pixel)
 * @param num_states Total number of states to initialize
 * @param seed Base seed for random number generation
 */
__global__ void init_random_states(curandState *rand_states, int num_states, unsigned long long seed)
{
   int idx = blockIdx.x * blockDim.x + threadIdx.x;
   if (idx < num_states)
   {
      // Initialize each state with a unique seed based on index
      curand_init(seed + idx, 0, 0, &rand_states[idx]);
   }
}

/**
 * @brief Main CUDA kernel for ray tracing entire image
 * Each thread processes one pixel with multiple samples for anti-aliasing
 * @param image Output image buffer (RGB, 8-bit per channel)
 * @param width Image width in pixels
 * @param height Image height in pixels
 * @param samples_per_pixel Number of rays per pixel for anti-aliasing
 * @param max_depth Maximum ray recursion depth
 * @param cam_center_* Camera center position components
 * @param pixel00_* Top-left pixel center position components
 * @param delta_u_* Pixel step in U direction components
 * @param delta_v_* Pixel step in V direction components
 * @param ray_count Global counter for rays traced
 * @param rand_states Shared array of random states (one per thread/pixel)
 */
__global__ void renderKernel(unsigned char *image, int width, int height, int samples_per_pixel, int max_depth,
                             float cam_center_x, float cam_center_y, float cam_center_z, float pixel00_x,
                             float pixel00_y, float pixel00_z, float delta_u_x, float delta_u_y, float delta_u_z,
                             float delta_v_x, float delta_v_y, float delta_v_z, curandState *rand_states)
{
   int x = blockIdx.x * blockDim.x + threadIdx.x;
   int y = blockIdx.y * blockDim.y + threadIdx.y;

   // Strict bounds checking
   if (x >= width || y >= height)
      return;

   int pixel_idx = y * width + x;
   int base_idx = pixel_idx * 3;

   // Double check bounds for memory access
   if (pixel_idx >= width * height || base_idx + 2 >= width * height * 3)
   {
      return;
   }

   // Use the pre-initialized random state for this pixel
   curandState *local_rand_state = &rand_states[pixel_idx];

   // Convert parameters to float3_simple
   float3_simple camera_center(cam_center_x, cam_center_y, cam_center_z);
   float3_simple pixel_color(0, 0, 0);

   pixel_color = pixel_color + float3_simple(random_float(local_rand_state), random_float(local_rand_state),
                                             random_float(local_rand_state));

   // Gamma correction (gamma=2)
   pixel_color.x = sqrtf(fmaxf(pixel_color.x, 0.0f));
   pixel_color.y = sqrtf(fmaxf(pixel_color.y, 0.0f));
   pixel_color.z = sqrtf(fmaxf(pixel_color.z, 0.0f));

   // Convert to bytes with clamping
   unsigned char r = (unsigned char)(255.0f * fminf(fmaxf(pixel_color.x, 0.0f), 1.0f));
   unsigned char g = (unsigned char)(255.0f * fminf(fmaxf(pixel_color.y, 0.0f), 1.0f));
   unsigned char b = (unsigned char)(255.0f * fminf(fmaxf(pixel_color.z, 0.0f), 1.0f));

   // Store in image buffer - each kernel writes to its own unique location
   image[base_idx] = r;
   image[base_idx + 1] = g;
   image[base_idx + 2] = b;
}

//==============================================================================
// HOST INTERFACE FUNCTIONS
//==============================================================================

/**
 * @brief Host function for tile-based rendering (useful for real-time display)
 * Renders only a rectangular portion of the image for progressive rendering
 * @param image Full image buffer (input/output)
 * @param width Full image width in pixels
 * @param height Full image height in pixels
 * @param cam_center_* Camera position components
 * @param pixel00_* Top-left pixel center position components
 * @param delta_u_* Pixel step in U direction components
 * @param delta_v_* Pixel step in V direction components
 * @param samples_per_pixel Number of rays per pixel for anti-aliasing
 * @param max_depth Maximum ray recursion depth
 */
extern "C" unsigned long long renderPixelsCUDA(unsigned char *image, int width, int height, double cam_center_x,
                                               double cam_center_y, double cam_center_z, double pixel00_x,
                                               double pixel00_y, double pixel00_z, double delta_u_x, double delta_u_y,
                                               double delta_u_z, double delta_v_x, double delta_v_y, double delta_v_z,
                                               int samples_per_pixel, int max_depth)
{

   // Allocate device memory for the full image (we need to maintain the full buffer)
   unsigned char *d_image;
   size_t image_size = width * height * 3 * sizeof(unsigned char);
   int num_pixels = width * height;

   // Random generato states
   curandState *d_rand_states;

   cudaError_t malloc_err1 = cudaMalloc(&d_image, image_size);
   cudaError_t malloc_err2 = cudaMalloc(&d_rand_states, num_pixels * sizeof(curandState));

   if (malloc_err1 != cudaSuccess || malloc_err2 != cudaSuccess)
   {
      printf("CUDA malloc error: %s, %s\n", cudaGetErrorString(malloc_err1), cudaGetErrorString(malloc_err2));
      return 0;
   }

   // Initialize random states for all pixels
   int threads_per_block = 256;
   int num_blocks = (num_pixels + threads_per_block - 1) / threads_per_block;
   init_random_states<<<num_blocks, threads_per_block>>>(d_rand_states, num_pixels, 1984);

   cudaError_t init_err = cudaGetLastError();
   if (init_err != cudaSuccess)
   {
      printf("CUDA random state init error: %s\n", cudaGetErrorString(init_err));
      cudaFree(d_image);
      cudaFree(d_rand_states);
      return 0;
   }

   cudaDeviceSynchronize();

   // Set up grid and block dimensions for the tile
   dim3 block_size(32, 4);
   dim3 grid_size((width + block_size.x - 1) / block_size.x, (height + block_size.y - 1) / block_size.y);

   printf("Tile grid size: (%d, %d), Block size: (%d, %d)\n", grid_size.x, grid_size.y, block_size.x, block_size.y);

   // Launch tile rendering kernel
   renderKernel<<<grid_size, block_size>>>(d_image, width, height, samples_per_pixel, max_depth, (float)cam_center_x,
                                           (float)cam_center_y, (float)cam_center_z, (float)pixel00_x, (float)pixel00_y,
                                           (float)pixel00_z, (float)delta_u_x, (float)delta_u_y, (float)delta_u_z,
                                           (float)delta_v_x, (float)delta_v_y, (float)delta_v_z, d_rand_states);

   // Check for kernel errors
   cudaError_t kernel_err = cudaGetLastError();
   if (kernel_err != cudaSuccess)
   {
      printf("CUDA kernel error: %s\n", cudaGetErrorString(kernel_err));
      cudaFree(d_image);
      return 0;
   }

   cudaDeviceSynchronize();

   // Copy result back to host
   cudaError_t copy_err = cudaMemcpy(image, d_image, image_size, cudaMemcpyDeviceToHost);
   if (copy_err != cudaSuccess)
   {
      printf("Memory copy error: %s\n", cudaGetErrorString(copy_err));
      cudaFree(d_image);
      return 0;
   }

   // Clean up
   cudaFree(d_image);

   return 1;
}