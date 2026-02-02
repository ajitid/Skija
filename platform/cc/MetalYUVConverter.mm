// MetalYUVConverter.mm - NV12 to BGRA conversion using Metal compute shader
// This allows zero-copy video playback by converting VideoToolbox NV12 output
// to BGRA that Skia can adopt directly.

#include <jni.h>
#include "interop.hh"

#ifdef SK_METAL
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

// Metal compute shader for NV12 (Y + UV bi-planar) to BGRA conversion
// Uses BT.709 color matrix (HD video standard)
static NSString* const kYUVToBGRAShader = @R"(
#include <metal_stdlib>
using namespace metal;

kernel void yuv_to_bgra(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<float, access::write> outTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Check bounds
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }

    // Sample Y at full resolution
    float y = yTexture.read(gid).r;

    // Sample UV at half resolution (NV12 is 4:2:0 subsampled)
    uint2 uvCoord = gid / 2;
    float2 uv = uvTexture.read(uvCoord).rg;

    // Convert from [0,1] to [-0.5, 0.5] for U and V
    float u = uv.r - 0.5;
    float v = uv.g - 0.5;

    // BT.709 YUV to RGB conversion (HD video standard)
    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;

    // Clamp and write as BGRA
    float4 bgra = float4(
        saturate(b),
        saturate(g),
        saturate(r),
        1.0
    );

    outTexture.write(bgra, gid);
}
)";

// Cached compute pipeline state
static id<MTLComputePipelineState> g_yuvPipelineState = nil;
static id<MTLDevice> g_cachedDevice = nil;

static id<MTLComputePipelineState> getOrCreatePipeline(id<MTLDevice> device) {
    if (g_yuvPipelineState && g_cachedDevice == device) {
        return g_yuvPipelineState;
    }

    NSError* error = nil;

    // Compile the shader
    id<MTLLibrary> library = [device newLibraryWithSource:kYUVToBGRAShader
                                                  options:nil
                                                    error:&error];
    if (!library) {
        NSLog(@"[MetalYUV] Failed to compile shader: %@", error);
        return nil;
    }

    id<MTLFunction> kernelFunction = [library newFunctionWithName:@"yuv_to_bgra"];
    if (!kernelFunction) {
        NSLog(@"[MetalYUV] Failed to find kernel function");
        return nil;
    }

    g_yuvPipelineState = [device newComputePipelineStateWithFunction:kernelFunction
                                                               error:&error];
    if (!g_yuvPipelineState) {
        NSLog(@"[MetalYUV] Failed to create pipeline state: %@", error);
        return nil;
    }

    g_cachedDevice = device;
    return g_yuvPipelineState;
}

extern "C" JNIEXPORT jlong JNICALL Java_io_github_humbleui_skija_Image__1nConvertYUVToRGBA
  (JNIEnv* env, jclass jclass, jlong devicePtr, jlong queuePtr,
   jlong yTexturePtr, jlong uvTexturePtr, jint width, jint height) {

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)(void*)devicePtr;
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)(void*)queuePtr;
        id<MTLTexture> yTexture = (__bridge id<MTLTexture>)(void*)yTexturePtr;
        id<MTLTexture> uvTexture = (__bridge id<MTLTexture>)(void*)uvTexturePtr;

        if (!device || !queue || !yTexture || !uvTexture) {
            NSLog(@"[MetalYUV] Invalid parameters");
            return 0;
        }

        // Get or create compute pipeline
        id<MTLComputePipelineState> pipelineState = getOrCreatePipeline(device);
        if (!pipelineState) {
            return 0;
        }

        // Create output texture (BGRA8Unorm)
        // Use Private storage with RenderTarget usage - this matches what Skia expects
        // for textures it can use as render targets
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        desc.storageMode = MTLStorageModePrivate;

        id<MTLTexture> outputTexture = [device newTextureWithDescriptor:desc];
        if (!outputTexture) {
            NSLog(@"[MetalYUV] Failed to create output texture");
            return 0;
        }

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        if (!commandBuffer) {
            NSLog(@"[MetalYUV] Failed to create command buffer");
            return 0;
        }

        // Create compute encoder
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        if (!encoder) {
            NSLog(@"[MetalYUV] Failed to create compute encoder");
            return 0;
        }

        [encoder setComputePipelineState:pipelineState];
        [encoder setTexture:yTexture atIndex:0];
        [encoder setTexture:uvTexture atIndex:1];
        [encoder setTexture:outputTexture atIndex:2];

        // Calculate thread groups
        MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
        MTLSize threadGroups = MTLSizeMake(
            (width + threadGroupSize.width - 1) / threadGroupSize.width,
            (height + threadGroupSize.height - 1) / threadGroupSize.height,
            1
        );

        [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupSize];
        [encoder endEncoding];

        // Submit and wait
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        // Return the output texture pointer (caller must manage lifetime)
        // We retain it so it survives the autorelease pool
        return (jlong)(__bridge_retained void*)outputTexture;
    }
}

extern "C" JNIEXPORT void JNICALL Java_io_github_humbleui_skija_Image__1nReleaseMetalTexture
  (JNIEnv* env, jclass jclass, jlong texturePtr) {
    if (texturePtr) {
        id<MTLTexture> texture = (__bridge_transfer id<MTLTexture>)(void*)texturePtr;
        texture = nil; // Release
    }
}

#endif // SK_METAL
