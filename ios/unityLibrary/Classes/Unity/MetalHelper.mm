#include "UnityTrampolineCompatibility.h"
#include "UnityRendering.h"

#if UNITY_CAN_USE_METAL

#include "UnityMetalSupport.h"
#include <QuartzCore/QuartzCore.h>
#include <libkern/OSAtomic.h>

#if UNITY_TRAMPOLINE_IN_USE
#include "UnityAppController.h"
#include "CVTextureCache.h"
#endif

#include "ObjCRuntime.h"

#if UNITY_TRAMPOLINE_IN_USE
static Class MTLTextureDescriptorClass;
#else
extern Class MTLTextureDescriptorClass;
#endif

extern "C" void InitRenderingMTL()
{
#if UNITY_TRAMPOLINE_IN_USE
    MTLTextureDescriptorClass = NSClassFromString(@"MTLTextureDescriptor");
#endif
}

static MTLPixelFormat GetColorFormatForSurface(const UnityDisplaySurfaceMTL* surface)
{
    MTLPixelFormat colorFormat = surface->srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;

    // at some point we tried using MTLPixelFormatBGR10_XR formats, but it seems that apple CoreImage have issues with that
    //   and we are not alone here, see for example https://forums.developer.apple.com/forums/thread/66166
    // when application goes to background the colors are changed (more white-ish?)
    // no matter what we tried, the issue persists
    // NOTE: the most funny thing is when we set color space to be P3 we get same whitish colors always
    // NOTE: but this time they become normal when going to background
    // in all, it seems that using rgba f16 is the most robust option here, so we are back to it again

#if PLATFORM_IOS || PLATFORM_TVOS
    if (surface->wideColor && UnityIsWideColorSupported())
        colorFormat = MTLPixelFormatRGBA16Float;
#elif PLATFORM_OSX
    if (surface->hdr)
    {
        if (@available(macOS 10.15, *))
        {
            colorFormat = UnityHDRSurfaceDepth() == 0 ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatRGBA16Float;
        }
    }
    else if (surface->wideColor)
        colorFormat = MTLPixelFormatRGBA16Float;
#endif

    return colorFormat;
}

static uint32_t GetCVPixelFormatForSurface(const UnityDisplaySurfaceMTL* surface)
{
    // this makes sense only for ios (at least we dont support this on macos)
    uint32_t colorFormat = kCVPixelFormatType_32BGRA;
#if PLATFORM_IOS || PLATFORM_TVOS
    if (surface->wideColor && UnityIsWideColorSupported())
        colorFormat = kCVPixelFormatType_30RGB;
#endif

    return colorFormat;
}

extern "C" void CreateSystemRenderingSurfaceMTL(UnityDisplaySurfaceMTL* surface)
{
    DestroySystemRenderingSurfaceMTL(surface);

    MTLPixelFormat colorFormat = GetColorFormatForSurface(surface);
    surface->layer.presentsWithTransaction = NO;
    surface->layer.drawsAsynchronously = YES;

#if !PLATFORM_OSX
    if (UnityPreserveFramebufferAlpha())
    {
        const CGFloat components[] = {1.0f, 1.0f, 1.0f, 0.0f};
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGColorRef color = CGColorCreate(colorSpace, components);
        surface->layer.opaque = NO;
        surface->layer.backgroundColor = color;
        CGColorRelease(color);
        CGColorSpaceRelease(colorSpace);
    }
#endif

#if PLATFORM_OSX
    surface->layer.opaque = YES;
    MetalUpdateDisplaySync();
#endif


#if PLATFORM_OSX
    CGColorSpaceRef colorSpaceRef = nil;
    if (surface->hdr)
        colorSpaceRef = UnityHDRSurfaceDepth() == 0 ? CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceITUR_2020_PQ_EOTF")) : CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceITUR_709"));
    else if (surface->wideColor)
        colorSpaceRef = CGColorSpaceCreateWithName(surface->srgb ? kCGColorSpaceExtendedLinearSRGB : kCGColorSpaceExtendedSRGB);
    else
        colorSpaceRef = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    surface->layer.colorspace = colorSpaceRef;
    CGColorSpaceRelease(colorSpaceRef);
#endif

    // Update the native screen resolution
    UnityUpdateDrawableSize(surface);

    surface->layer.device = surface->device;
    surface->layer.pixelFormat = colorFormat;
    surface->layer.framebufferOnly = (surface->framebufferOnly != 0);
    surface->colorFormat = (unsigned)colorFormat;

    MTLTextureDescriptor* txDesc = [MTLTextureDescriptorClass texture2DDescriptorWithPixelFormat: colorFormat width: surface->systemW height: surface->systemH mipmapped: NO];
#if PLATFORM_OSX
    txDesc.resourceOptions = MTLResourceCPUCacheModeDefaultCache | MTLResourceStorageModeManaged;
#endif
    txDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

    @synchronized(surface->layer)
    {
#if PLATFORM_OSX
        surface->proxySwaps = 0;
        surface->proxyReady = 0;
        surface->calledPresentDrawable = 0;
        surface->vsync = 1; // by default, vsync is enabled for all surfaces
#endif

        for (int i = 0; i < kUnityNumOffscreenSurfaces; i++)
        {
            // Allocating a proxy texture is cheap until it's being rendered to and the GPU driver does allocation
            surface->drawableProxyRT[i] = [surface->device newTextureWithDescriptor: txDesc];
            surface->drawableProxyRT[i].label = @"DrawableProxy";

        #if PLATFORM_IOS || PLATFORM_TVOS
            [surface->drawableProxyRT[i] setPurgeableState: MTLPurgeableStateEmpty];
        #endif

            // Mark each drawableProxy surface as needing a clear load action when next rendered to as its contents are undefined.
            surface->drawableProxyNeedsClear[i] = true;
        }
    }
}

extern "C" void CreateRenderingSurfaceMTL(UnityDisplaySurfaceMTL* surface)
{
    DestroyRenderingSurfaceMTL(surface);

    MTLPixelFormat colorFormat = GetColorFormatForSurface(surface);

    const int w = surface->targetW, h = surface->targetH;

    if (w != surface->systemW || h != surface->systemH || surface->useCVTextureCache)
    {
#if PLATFORM_IOS || PLATFORM_TVOS
        if (surface->useCVTextureCache)
            surface->cvTextureCache = CreateCVTextureCache();

        if (surface->cvTextureCache)
        {
            surface->cvTextureCacheTexture = CreateReadableRTFromCVTextureCache2(surface->cvTextureCache, surface->targetW, surface->targetH,
                GetCVPixelFormatForSurface(surface), colorFormat, &surface->cvPixelBuffer);
            surface->targetColorRT = GetMetalTextureFromCVTextureCache(surface->cvTextureCacheTexture);
        }
        else
#endif
        {
            MTLTextureDescriptor* txDesc = [MTLTextureDescriptorClass new];
            txDesc.textureType = MTLTextureType2D;
            txDesc.width = w;
            txDesc.height = h;
            txDesc.depth = 1;
            txDesc.pixelFormat = colorFormat;
            txDesc.arrayLength = 1;
            txDesc.mipmapLevelCount = 1;
#if PLATFORM_OSX
            txDesc.resourceOptions = MTLResourceStorageModeManaged;
#endif
            txDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            surface->targetColorRT = [surface->device newTextureWithDescriptor: txDesc];
        }
        surface->targetColorRT.label = @"targetColorRT";
    }

    if (surface->msaaSamples > 1)
    {
        MTLTextureDescriptor* txDesc = [MTLTextureDescriptorClass new];
        txDesc.textureType = MTLTextureType2DMultisample;
        txDesc.width = w;
        txDesc.height = h;
        txDesc.depth = 1;
        txDesc.pixelFormat = colorFormat;
        txDesc.arrayLength = 1;
        txDesc.mipmapLevelCount = 1;
        txDesc.sampleCount = surface->msaaSamples;
        txDesc.resourceOptions = MTLResourceStorageModePrivate;
        txDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        if (![surface->device supportsTextureSampleCount: txDesc.sampleCount])
            txDesc.sampleCount = 4;
        surface->targetAAColorRT = [surface->device newTextureWithDescriptor: txDesc];
        surface->targetAAColorRT.label = @"targetAAColorRT";
    }
}

extern "C" void DestroyRenderingSurfaceMTL(UnityDisplaySurfaceMTL* surface)
{
    surface->targetColorRT = nil;
    surface->targetAAColorRT = nil;

    if (surface->cvTextureCacheTexture)
        CFRelease(surface->cvTextureCacheTexture);
    if (surface->cvPixelBuffer)
        CFRelease(surface->cvPixelBuffer);
    if (surface->cvTextureCache)
        CFRelease(surface->cvTextureCache);
    surface->cvTextureCache = 0;
}

extern "C" void CreateSharedDepthbufferMTL(UnityDisplaySurfaceMTL* surface)
{
    DestroySharedDepthbufferMTL(surface);
    if (surface->disableDepthAndStencil)
        return;

    MTLPixelFormat pixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    MTLTextureDescriptor* depthTexDesc = [MTLTextureDescriptorClass texture2DDescriptorWithPixelFormat: pixelFormat width: surface->targetW height: surface->targetH mipmapped: NO];
    depthTexDesc.resourceOptions = MTLResourceStorageModePrivate;

#if PLATFORM_IOS || PLATFORM_TVOS
    if (surface->memorylessDepth)
        depthTexDesc.storageMode = MTLStorageModeMemoryless;
#endif

    depthTexDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    if (surface->msaaSamples > 1)
    {
        depthTexDesc.textureType = MTLTextureType2DMultisample;
        depthTexDesc.sampleCount = surface->msaaSamples;
        if (![surface->device supportsTextureSampleCount: depthTexDesc.sampleCount])
            depthTexDesc.sampleCount = 4;
    }
    surface->depthRB = [surface->device newTextureWithDescriptor: depthTexDesc];
    surface->stencilRB = surface->depthRB;
}

extern "C" void DestroySharedDepthbufferMTL(UnityDisplaySurfaceMTL* surface)
{
    surface->depthRB = nil;
    surface->stencilRB = nil;
}

extern "C" void CreateUnityRenderBuffersMTL(UnityDisplaySurfaceMTL* surface)
{
    UnityRenderBufferDesc sys_desc = { surface->systemW, surface->systemH, 1, 1, 1 };
    UnityRenderBufferDesc tgt_desc = { surface->targetW, surface->targetH, 1, (unsigned int)surface->msaaSamples, 1 };

    // To avoid race condition with EndFrameRenderingMTL where systemColorRB is nulled we store it here
    MTLTextureRef systemColorRB = surface->drawableProxyRT[0];
    surface->systemColorRB = systemColorRB;

    // we could unify all of it with ugly chain of ternary operators but what if karma exists?

    if (surface->targetColorRT)
    {
        // render to interim RT: we do NOT need to request drawable
        MTLTextureRef texRender     = surface->targetAAColorRT ? surface->targetAAColorRT : surface->targetColorRT;
        MTLTextureRef texResolve    = surface->targetAAColorRT ? surface->targetColorRT : nil;
        surface->unityColorBuffer   = UnityCreateExternalColorSurfaceMTL(surface->unityColorBuffer, texRender, texResolve, &tgt_desc, nil);
    }
    else
    {
        // render to backbuffer directly: we will request drawable hence we need to pass surface
        MTLTextureRef texRender     = surface->targetAAColorRT ? surface->targetAAColorRT : systemColorRB;
        MTLTextureRef texResolve    = surface->targetAAColorRT ? systemColorRB : nil;

        surface->unityColorBuffer   = UnityCreateExternalColorSurfaceMTL(surface->unityColorBuffer, texRender, texResolve, &tgt_desc, surface);
    }

    if (surface->depthRB)
        surface->unityDepthBuffer   = UnityCreateExternalDepthSurfaceMTL(surface->unityDepthBuffer, surface->depthRB, surface->stencilRB, &tgt_desc);
    else
        surface->unityDepthBuffer   = UnityCreateDummySurface(surface->unityDepthBuffer, false, &tgt_desc);

    surface->systemColorBuffer = UnityCreateExternalColorSurfaceMTL(surface->systemColorBuffer, systemColorRB, nil, &sys_desc, surface);
    surface->systemDepthBuffer = UnityCreateDummySurface(surface->systemDepthBuffer, false, &sys_desc);
}

extern "C" void DestroySystemRenderingSurfaceMTL(UnityDisplaySurfaceMTL* surface)
{
    // before we needed to nil surface->systemColorRB (to release drawable we get from the view)
    // but after we switched to proxy rt this is no longer needed
    // even more it is harmful when running rendering on another thread (as is default now)
    // as on render thread we do StartFrameRenderingMTL/AcquireDrawableMTL/EndFrameRenderingMTL
    // and DestroySystemRenderingSurfaceMTL comes on main thread so we might end up with race condition for no reason
}

extern "C" void DestroyUnityRenderBuffersMTL(UnityDisplaySurfaceMTL* surface)
{
    UnityDestroyExternalSurface(surface->unityColorBuffer);
    UnityDestroyExternalSurface(surface->systemColorBuffer);
    surface->unityColorBuffer = surface->systemColorBuffer = 0;

    UnityDestroyExternalSurface(surface->unityDepthBuffer);
    UnityDestroyExternalSurface(surface->systemDepthBuffer);
    surface->unityDepthBuffer = surface->systemDepthBuffer = 0;
}

extern "C" void PreparePresentMTL(UnityDisplaySurfaceMTL* surface)
{
    if (surface->targetColorRT)
        UnityBlitToBackbuffer(surface->unityColorBuffer, surface->systemColorBuffer, surface->systemDepthBuffer);
#if UNITY_TRAMPOLINE_IN_USE
    APP_CONTROLLER_RENDER_PLUGIN_METHOD(onFrameResolved);
#endif
}

extern "C" void PresentMTL(UnityDisplaySurfaceMTL* surface)
{
    //ARCHEOLOGY: we used to present using [MTLCommandBuffer presentDrawable:afterMinimumDuration:]
    //however that was found to sometimes cause 0.5s-1s hangs when acquiring drawable after surface rebuild, or presenting hanging completely (UUM-9480)
    //after some further investigation we found that using the more complex present logic didn't actually yield much benefit
    //current implementation is made to align with our macOS present logic
    if (surface->drawable)
    {
        id<CAMetalDrawable> drawable = surface->drawable;

        [UnityCurrentMTLCommandBuffer() addScheduledHandler:^(id<MTLCommandBuffer> commandBuffer) {
            [drawable present];
        }];
    }
    surface->calledPresentDrawable = 1;
}

extern "C" MTLTextureRef AcquireDrawableMTL(UnityDisplaySurfaceMTL* surface)
{
    if (!surface)
        return nil;

    if (!surface->drawable)
        surface->drawable = [surface->layer nextDrawable];

    // on A7 SoC nextDrawable may be nil before locking the screen
    if (!surface->drawable)
        return nil;

    surface->systemColorRB = [surface->drawable texture];
    return surface->systemColorRB;
}

extern "C" int UnityCommandQueueMaxCommandBufferCountMTL()
{
    // customizable argument to pass towards [MTLDevice newCommandQueueWithMaxCommandBufferCount:],
    // the default value is 64 but with Parallel Render Encoder workloads, it might need to be increased

    return 256;
}

extern "C" void StartFrameRenderingMTL(UnityDisplaySurfaceMTL* surface)
{
    // we will acquire drawable lazily in AcquireDrawableMTL
    surface->drawable = nil;
    surface->systemColorRB  = surface->drawableProxyRT[0];

    UnityRenderBufferDesc sys_desc = { surface->systemW, surface->systemH, 1, 1, 1};
    UnityRenderBufferDesc tgt_desc = { surface->targetW, surface->targetH, 1, (unsigned int)surface->msaaSamples, 1};

    surface->systemColorBuffer = UnityCreateExternalColorSurfaceMTL(surface->systemColorBuffer, surface->systemColorRB, nil, &sys_desc, surface);
    if (surface->targetColorRT == nil)
    {
        if (surface->targetAAColorRT)
            surface->unityColorBuffer = UnityCreateExternalColorSurfaceMTL(surface->unityColorBuffer, surface->targetAAColorRT, surface->systemColorRB, &tgt_desc, surface);
        else
            surface->unityColorBuffer = UnityCreateExternalColorSurfaceMTL(surface->unityColorBuffer, surface->systemColorRB, nil, &tgt_desc, surface);
    }
}

extern "C" void EndFrameRenderingMTL(UnityDisplaySurfaceMTL* surface)
{
    @autoreleasepool
    {
        if (surface->presentCB)
        {
            [surface->presentCB enqueue]; [surface->presentCB commit];
            surface->presentCB = nil;
        }

        surface->systemColorRB  = surface->drawableProxyRT[0];
        surface->drawable       = nil;
    }

#if PLATFORM_OSX
    @synchronized(surface->layer)
    {
        if (!surface->calledPresentDrawable)
            return;
        surface->calledPresentDrawable = 0;
        std::swap(surface->drawableProxyRT[0], surface->drawableProxyRT[1]);

        surface->proxySwaps++;
        surface->proxyReady = 1;

        // Swap the needs clear state of the swapped proxy buffers, to ensure that each surface
        // will get cleared at least once when the proxy buffer surfaces are recreated.
        std::swap(surface->drawableProxyNeedsClear[0],
            surface->drawableProxyNeedsClear[1]);
    }
#endif
}

extern "C" void PreparePresentNonMainScreenMTL(UnityDisplaySurfaceMTL* surface)
{
    if (surface->drawable)
    {
        // presentCB logic should be removed when we update the minimum version to iOS 12.0
        // as the "one presentDrawable per command buffer" behaviour apparently was fixed
        if (@available(iOS 12.0, *))
        {
            [UnityCurrentMTLCommandBuffer() presentDrawable: surface->drawable];
        }
        else
        {
            surface->presentCB = [surface->drawableCommandQueue commandBuffer];
            [surface->presentCB presentDrawable: surface->drawable];
        }
    }
}

extern "C" void SetDrawableSizeMTL(UnityDisplaySurfaceMTL* surface, int width, int height)
{
    surface->layer.drawableSize = CGSizeMake(width, height);
}

#else

extern "C" void InitRenderingMTL()                                          {}

extern "C" void CreateSystemRenderingSurfaceMTL(UnityDisplaySurfaceMTL*)    {}
extern "C" void CreateRenderingSurfaceMTL(UnityDisplaySurfaceMTL*)          {}
extern "C" void DestroyRenderingSurfaceMTL(UnityDisplaySurfaceMTL*)         {}
extern "C" void CreateSharedDepthbufferMTL(UnityDisplaySurfaceMTL*)         {}
extern "C" void DestroySharedDepthbufferMTL(UnityDisplaySurfaceMTL*)        {}
extern "C" void CreateUnityRenderBuffersMTL(UnityDisplaySurfaceMTL*)        {}
extern "C" void DestroySystemRenderingSurfaceMTL(UnityDisplaySurfaceMTL*)   {}
extern "C" void DestroyUnityRenderBuffersMTL(UnityDisplaySurfaceMTL*)       {}
extern "C" void StartFrameRenderingMTL(UnityDisplaySurfaceMTL*)             {}
extern "C" void EndFrameRenderingMTL(UnityDisplaySurfaceMTL*)               {}
extern "C" void PreparePresentMTL(UnityDisplaySurfaceMTL*)                  {}
extern "C" void PresentMTL(UnityDisplaySurfaceMTL*)                         {}
extern "C" int  UnityCommandQueueMaxCommandBufferCountMTL()                 { return 0; }
extern "C" void SetDrawableSizeMTL(UnityDisplaySurfaceMTL*, int, int)       {}

extern "C" MTLTextureRef    AcquireDrawableMTL(UnityDisplaySurfaceMTL*)     { return nil; }


#endif
