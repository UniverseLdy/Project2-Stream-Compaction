#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "efficient.h"

#define BLOCKSIZE 128
namespace StreamCompaction {
    namespace Efficient {
        using StreamCompaction::Common::PerformanceTimer;
        PerformanceTimer& timer()
        {
            static PerformanceTimer timer;
            return timer;
        }
        __global__ void kernUpSweep(int n, int d, int* idata) {
            int index = threadIdx.x + (blockIdx.x * blockDim.x);
            if (index >= n) {
                return;
            }
            int offset = 1 << d; //2^d
            int offsetDouble = offset * 2; //2^(d+1)
            int indexRemap = index * offsetDouble;
            idata[indexRemap + offsetDouble - 1] += idata[indexRemap + offset - 1];
        }

        __global__ void kernDownSweep(int n, int d, int* idata) {
            int index = threadIdx.x + (blockIdx.x * blockDim.x);
            if (index >= n) {
                return;
            }
            int offset = 1 << d; //2^d
            int offsetDouble = offset * 2; //2^(d+1)
            int indexRemap = index * offsetDouble;
            int temp = idata[indexRemap + offset - 1];
            idata[indexRemap + offset - 1] = idata[indexRemap + offsetDouble - 1];
            idata[indexRemap + offsetDouble - 1] += temp;
        }

        //For radix sort extra credits

        __global__ void kernRadixBarray(int n, int bitNum, const int* idata, int* bArray, int* eArray)
        {
            int index = threadIdx.x + (blockIdx.x * blockDim.x);
            if (index >= n) {
                return;
            }
            bArray[index] = (idata[index] >> bitNum & 1) ? 1 : 0;
            eArray[index] = (idata[index] >> bitNum & 1) ? 0 : 1;
        }

        __global__ void kernRadixTarray(int n, const int* fArray, int* tArray, int d)
        {
            int index = threadIdx.x + (blockIdx.x * blockDim.x);
            if (index >= n) {
                return;
            }
            tArray[index] = index - fArray[index] + d;
        }

        __global__ void kernRadixDarray(int n, const int* bArray, const int* fArray, const int* tArray, int* dArray)
        {
            int index = threadIdx.x + (blockIdx.x * blockDim.x);
            if (index >= n) {
                return;
            }
            dArray[index] = (bArray[index]) ? tArray[index] : dArray[index];
        }

        __global__ void kernRadixRemap(int n, const int* dArray, int* idata)
        {
            int index = threadIdx.x + (blockIdx.x * blockDim.x);
            if (index >= n) {
                return;
            }
            idata[dArray[index]]= idata[index];
        }
        /**
         * Performs prefix-sum (aka scan) on idata, storing the result into odata.
         */
        void scan(int n, int *odata, const int *idata) {
            int size = powf(2, ilog2ceil(n));
            int* dev_idata;
            cudaMalloc((void**)&dev_idata, size * sizeof(int));
            cudaMemcpy(dev_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
            timer().startGpuTimer();
            dim3 blockSize(BLOCKSIZE);
            dim3 gridSize((size + BLOCKSIZE - 1) / BLOCKSIZE);
            // TODO
            int d = ilog2ceil(n) - 1;
            for (int i = 0; i <= d; ++i) {
                int threadsNum = 1 << (d - i);
                gridSize = dim3((threadsNum + BLOCKSIZE - 1) / BLOCKSIZE);
                kernUpSweep << <gridSize, blockSize >> > (threadsNum, i, dev_idata);
            }
            cudaMemset((void*)&(dev_idata[size - 1]), 0, sizeof(int));

            for (int j = d; j >= 0; --j) {
                int threadsNum = 1 << (d - j);
                gridSize = dim3((threadsNum + BLOCKSIZE - 1) / BLOCKSIZE);
                kernDownSweep << <gridSize, blockSize >> > (threadsNum, j, dev_idata);
            }
            timer().endGpuTimer();

            cudaMemcpy(odata, dev_idata, n * sizeof(int), cudaMemcpyDeviceToHost);
            checkCUDAError("cudaMemcpy odata failed!");
            cudaFree(dev_idata);
            checkCUDAError("cudaFree(dev_idata) failed!");
        }

        /**
         * Performs stream compaction on idata, storing the result into odata.
         * All zeroes are discarded.
         *
         * @param n      The number of elements in idata.
         * @param odata  The array into which to store elements.
         * @param idata  The array of elements to compact.
         * @returns      The number of elements remaining after compaction.
         */
        int compact(int n, int *odata, const int *idata) {

            int pow2d = powf(2, ilog2ceil(n));
            int* boolArray;
            int* indexArray;
            int* dev_idata;
            int* dev_odata;
            int* dev_boolArray;
            int* dev_indexArray;

            cudaMalloc((void**)&dev_idata, n * sizeof(int));
            cudaMalloc((void**)&dev_odata, n * sizeof(int));
            cudaMalloc((void**)&dev_boolArray, n * sizeof(int));
            cudaMalloc((void**)&dev_indexArray, pow2d * sizeof(int)); // This takes more memory space.

            boolArray = (int*)malloc(n * sizeof(int));
            indexArray = (int*)malloc(n * sizeof(int));

            int gridSize = (n + BLOCKSIZE - 1) / BLOCKSIZE;
            int gridSize2 = (pow2d + BLOCKSIZE - 1) / BLOCKSIZE;
            // copy memory to device
            cudaMemcpy(dev_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
            timer().startGpuTimer();
            // TODO
            // Map the boolean array
            StreamCompaction::Common::kernMapToBoolean << <gridSize, BLOCKSIZE >> > (n, dev_boolArray, dev_idata);
            // Do an exclusive scan
            cudaMemcpy(dev_indexArray, dev_boolArray, n * sizeof(int), cudaMemcpyDeviceToDevice);

            int d = ilog2ceil(n) - 1;
            for (int i = 0; i <= d; ++i) {
                int threadsNum = 1 << (d - i);
                gridSize2 = (threadsNum + BLOCKSIZE - 1) / BLOCKSIZE;
                kernUpSweep << <gridSize2, BLOCKSIZE >> > (threadsNum, i, dev_indexArray);
            }
            cudaMemset((void*)&(dev_indexArray[pow2d - 1]), 0, sizeof(int));

            for (int j = d; j >= 0; --j) {
                int threadsNum = 1 << (d - j);
                gridSize2 = (threadsNum + BLOCKSIZE - 1) / BLOCKSIZE;
                kernDownSweep << <gridSize2, BLOCKSIZE >> > (threadsNum, j, dev_indexArray);
            }

            // Scatter
            StreamCompaction::Common::kernScatter << <gridSize, BLOCKSIZE >> > (n, dev_odata, dev_idata, dev_boolArray, dev_indexArray);


            timer().endGpuTimer();

            // Copy the memory out
            cudaMemcpy(indexArray, dev_indexArray, n * sizeof(int), cudaMemcpyDeviceToHost);
            checkCUDAError("get indexArray failed!");
            cudaMemcpy(boolArray, dev_boolArray, n * sizeof(int), cudaMemcpyDeviceToHost);
            checkCUDAError("get boolArray failed!");
            cudaMemcpy(odata, dev_odata, n * sizeof(int), cudaMemcpyDeviceToHost);
            checkCUDAError("get odata failed!");

            int count = boolArray[n - 1] ? indexArray[n - 1] + 1 : indexArray[n - 1];

            // Free Mem spaces
            cudaFree(dev_idata);
            checkCUDAError("cudaFree(dev_idata) failed!");
            cudaFree(dev_odata);
            checkCUDAError("cudaFree(dev_odata) failed!");
            cudaFree(dev_boolArray);
            checkCUDAError("cudaFree(dev_boolArray) failed!");
            cudaFree(dev_indexArray);
            checkCUDAError("cudaFree(dev_indexArray) failed!");

            free(boolArray);
            free(indexArray);

            return count;
        }

        void radixSort(int n, int bitNum, int* odata, int* idata)
        {
            int* dev_idata;
            int* dev_bArray;
            int* dev_eArray; 
            int* dev_fArray; 
            int* dev_tArray;
            int* dev_dArray;

            int* fArray;
            int* eArray;
            //Malloc
            cudaMalloc((void**)&dev_idata, n * sizeof(int));
            cudaMalloc((void**)&dev_bArray, n * sizeof(int));
            cudaMalloc((void**)&dev_eArray, n * sizeof(int));
            cudaMalloc((void**)&dev_fArray, n * sizeof(int));
            cudaMalloc((void**)&dev_tArray, n * sizeof(int));
            cudaMalloc((void**)&dev_dArray, n * sizeof(int));

            fArray = (int*)malloc(n * sizeof(int));
            eArray = (int*)malloc(n * sizeof(int));

            dim3 blockSize(BLOCKSIZE);
            dim3 gridSize((n + BLOCKSIZE - 1) / BLOCKSIZE);

            //Copy data from host to device
            cudaMemcpy(dev_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
            checkCUDAError("cudaMemcpy dev_idata failed!");
            int falseCount = 0;

            for (int i = 0; i < bitNum; ++i)
            {
                //Get B-array and E-array
                kernRadixBarray << <gridSize, blockSize>> > (n, i, dev_idata, dev_bArray, dev_eArray);
                //Get F-array
                StreamCompaction::Efficient::scan(n, dev_fArray, dev_eArray);
                cudaMemcpy(fArray, dev_fArray, n * sizeof(int), cudaMemcpyDeviceToHost);
                cudaMemcpy(eArray, dev_eArray, n * sizeof(int), cudaMemcpyDeviceToHost);
                falseCount = fArray[n - 1] + eArray[n - 1];

                kernRadixTarray << <gridSize, blockSize>> > (n, dev_fArray, dev_tArray, falseCount);
                kernRadixDarray << <gridSize, blockSize>> > (n, dev_bArray, dev_fArray, dev_tArray, dev_dArray);

                //Scatter
                kernRadixRemap << <gridSize, blockSize>> > (n, dev_dArray, dev_idata);
            }

            cudaMemcpy(odata, dev_idata, n * sizeof(int), cudaMemcpyDeviceToHost);//get the result
            checkCUDAError("get odata failed!\n");

            cudaFree(dev_idata);
            cudaFree(dev_bArray);
            cudaFree(dev_eArray);
            cudaFree(dev_fArray);
            cudaFree(dev_tArray);
            cudaFree(dev_dArray);

            free(fArray);
            free(eArray);
        }
    }
}
