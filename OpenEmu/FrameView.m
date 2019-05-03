// Copyright (c) 2019, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

@import MetalKit;

#import "FrameView.h"
#import "OEMTLPixelConverter.h"
#import <slang.h>

extern MTLPixelFormat glslang_format_to_metal(glslang_format fmt);
MTLPixelFormat SelectOptimalPixelFormat(MTLPixelFormat fmt);


#define MTLALIGN(x) __attribute__((aligned(x)))

typedef struct
{
    float x;
    float y;
    float z;
    float w;
} float4_t;

typedef struct texture
{
    id<MTLTexture> view;
    float4_t size_data;
} texture_t;

@implementation FrameView
{
    id<MTLDevice> _device;
    MTKTextureLoader *_loader;
    OEMTLPixelConverter *_converter;
    id<MTLTexture> _texture; // final render texture
    Vertex _vertex[4];
    OEIntSize _size; // size of view in pixels
        
    id<MTLTexture> _src;    // src texture
    bool _srcDirty;
    
    id<MTLSamplerState> _samplers[ShaderPassFilterCount][ShaderPassWrapCount];
    
    SlangShader *_shader;
    
    NSUInteger _frameCount;
    NSUInteger _passSize;
    NSUInteger _lutSize;
    NSUInteger _historySize;
    
    struct
    {
        texture_t texture[kMaxFrameHistory + 1];
        MTLViewport viewport;
        float4_t output_size;
    } _outputFrame;
    
    struct
    {
        id<MTLBuffer> buffers[SLANG_CBUFFER_MAX];
        texture_t rt;
        texture_t feedback;
        uint32_t frame_count;
        uint32_t frame_count_mod;
        pass_semantics_t semantics;
        MTLViewport viewport;
        id<MTLRenderPipelineState> _state;
        BOOL hasFeedback;
    } _pass[kMaxShaderPasses];
    
    texture_t _luts[kMaxTextures];
    
    bool _resizeRenderTargets;
    bool init_history;
    OEMTLViewport _viewport;
}

- (instancetype)initWithFormat:(OEMTLPixelFormat)format
                        device:(id<MTLDevice>)device
                     converter:(OEMTLPixelConverter *)converter
{
    self = [super init];
    
    _format = format;
    _device = device;
    _loader = [[MTKTextureLoader alloc] initWithDevice:device];
    _converter = converter;
    [self _initSamplers];
    _resizeRenderTargets = YES;

    Vertex v[4] = {
        {simd_make_float4(0, 1, 0, 1), simd_make_float2(0, 1)},
        {simd_make_float4(1, 1, 0, 1), simd_make_float2(1, 1)},
        {simd_make_float4(0, 0, 0, 1), simd_make_float2(0, 0)},
        {simd_make_float4(1, 0, 0, 1), simd_make_float2(1, 0)},
    };
    memcpy(_vertex, v, sizeof(_vertex));
    
    return self;
}

- (void)_initSamplers
{
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    
    /* Initialize samplers */
    for (unsigned i = 0; i < ShaderPassWrapCount; i++)
    {
        switch (i)
        {
            case ShaderPassWrapBorder:
                sd.sAddressMode = MTLSamplerAddressModeClampToBorderColor;
                break;
                
            case ShaderPassWrapEdge:
                sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
                break;
                
            case ShaderPassWrapRepeat:
                sd.sAddressMode = MTLSamplerAddressModeRepeat;
                break;
                
            case ShaderPassWrapMirroredRepeat:
                sd.sAddressMode = MTLSamplerAddressModeMirrorRepeat;
                break;
                
            default:
                continue;
        }
        sd.tAddressMode = sd.sAddressMode;
        sd.rAddressMode = sd.sAddressMode;
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        
        id<MTLSamplerState> ss = [_device newSamplerStateWithDescriptor:sd];
        _samplers[ShaderPassFilterLinear][i] = ss;
        
        sd.minFilter = MTLSamplerMinMagFilterNearest;
        sd.magFilter = MTLSamplerMinMagFilterNearest;
        
        ss = [_device newSamplerStateWithDescriptor:sd];
        _samplers[ShaderPassFilterNearest][i] = ss;
    }
}

- (void)setFilteringIndex:(int)index smooth:(bool)smooth
{
    for (int i = 0; i < ShaderPassWrapCount; i++)
    {
        if (smooth)
            _samplers[ShaderPassFilterUnspecified][i] = _samplers[ShaderPassFilterLinear][i];
        else
            _samplers[ShaderPassFilterUnspecified][i] = _samplers[ShaderPassFilterNearest][i];
    }
}

- (void)setSize:(OEIntSize)size
{
    if (OEIntSizeEqualToSize(_size, size))
    {
        return;
    }
    
    _size = size;
    
    _resizeRenderTargets = YES;
    
    if (_format != OEMTLPixelFormatBGRA8Unorm && _format != OEMTLPixelFormatBGRX8Unorm)
    {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Uint
                                                                                      width:size.width
                                                                                     height:size.height
                                                                                  mipmapped:NO];
        _src = [_device newTextureWithDescriptor:td];
    }
}

- (OEIntSize)size
{
    return _size;
}

- (void)_convertFormatWithContext:(id<OEMTLRenderContext>)ctx
{
    if (_format == OEMTLPixelFormatBGRA8Unorm || _format == OEMTLPixelFormatBGRX8Unorm)
        return;
    
    if (!_srcDirty)
        return;
    
    [_converter convertFormat:_format from:_src to:_texture commandBuffer:ctx.blitCommandBuffer];
    _srcDirty = NO;
}

- (void)_updateHistory
{
    if (_shader)
    {
        if (_historySize)
        {
            if (init_history)
                [self _initHistory];
            else
            {
                texture_t tmp = _outputFrame.texture[_historySize];
                for (NSUInteger k = _historySize; k > 0; k--)
                    _outputFrame.texture[k] = _outputFrame.texture[k - 1];
                _outputFrame.texture[0] = tmp;
            }
        }
    }
    
    /* either no history, or we moved a texture of a different size in the front slot */
    if (_outputFrame.texture[0].size_data.x != _size.width ||
        _outputFrame.texture[0].size_data.y != _size.height)
    {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:_size.width
                                                                                     height:_size.height
                                                                                  mipmapped:false];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        [self _initTexture:&_outputFrame.texture[0] withDescriptor:td];
    }
}

- (void)setViewport:(OEMTLViewport)viewport
{
    if (memcmp(&viewport, &_viewport, sizeof(viewport)) == 0)
    {
        return;
    }
    
    _viewport = viewport;
    
    OEIntRect view = viewport.view;
    
    _outputFrame.viewport.originX = view.origin.x;
    _outputFrame.viewport.originY = view.origin.y;
    _outputFrame.viewport.width = view.size.width;
    _outputFrame.viewport.height = view.size.height;
    _outputFrame.viewport.znear = 0.0f;
    _outputFrame.viewport.zfar = 1.0f;
    _outputFrame.output_size.x = view.size.width;
    _outputFrame.output_size.y = view.size.height;
    _outputFrame.output_size.z = 1.0f / view.size.width;
    _outputFrame.output_size.w = 1.0f / view.size.height;
    
    if (_shader) {
        _resizeRenderTargets = YES;
    }
}

- (void)updateFrame:(void const *)src pitch:(NSUInteger)pitch
{
    _frameCount++;
    
    if (_resizeRenderTargets)
    {
        [self _updateRenderTargets];
    }
    
    [self _updateHistory];
    
    if (_format == OEMTLPixelFormatBGRA8Unorm || _format == OEMTLPixelFormatBGRX8Unorm)
    {
        id<MTLTexture> tex = _outputFrame.texture[0].view;
        [tex replaceRegion:MTLRegionMake2D(0, 0, _size.width, _size.height)
               mipmapLevel:0 withBytes:src
               bytesPerRow:pitch];
    }
    else
    {
        [_src replaceRegion:MTLRegionMake2D(0, 0, _size.width, _size.height)
                mipmapLevel:0 withBytes:src
                bytesPerRow:(NSUInteger)(pitch)];
        _srcDirty = YES;
    }
}

- (void)_initTexture:(texture_t *)t withDescriptor:(MTLTextureDescriptor *)td
{
    t->view = [_device newTextureWithDescriptor:td];
    t->size_data.x = td.width;
    t->size_data.y = td.height;
    t->size_data.z = 1.0f / td.width;
    t->size_data.w = 1.0f / td.height;
}

- (void)_initTexture:(texture_t *)t withTexture:(id<MTLTexture>)tex
{
    t->view = tex;
    t->size_data.x = tex.width;
    t->size_data.y = tex.height;
    t->size_data.z = 1.0f / tex.width;
    t->size_data.w = 1.0f / tex.height;
}

- (void)_initHistory
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:_size.width
                                                                                 height:_size.height
                                                                              mipmapped:false];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    
    for (int i = 0; i < _historySize + 1; i++)
    {
        [self _initTexture:&_outputFrame.texture[i] withDescriptor:td];
    }
    init_history = NO;
}

- (void)drawWithEncoder:(id<MTLRenderCommandEncoder>)rce
{
    if (_texture)
    {
        [rce setViewport:_outputFrame.viewport];
        [rce setVertexBytes:&_vertex length:sizeof(_vertex) atIndex:BufferIndexPositions];
        [rce setFragmentTexture:_texture atIndex:TextureIndexColor];
        [rce drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
}

- (BOOL)drawWithContext:(id<OEMTLRenderContext>)ctx
{
    _texture = _outputFrame.texture[0].view;
    [self _convertFormatWithContext:ctx];
    
    if (!_shader || _passSize == 0)
    {
        return YES;
    }
    
    for (NSUInteger i = 0; i < _passSize; i++)
    {
        if (_pass[i].hasFeedback)
        {
            texture_t tmp = _pass[i].feedback;
            _pass[i].feedback = _pass[i].rt;
            _pass[i].rt = tmp;
        }
    }
    
    id<MTLCommandBuffer> cb = nil;;
    if (_passSize > 1 && _pass[0].rt.view != nil)
    {
        cb = ctx.blitCommandBuffer;
    }
    
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor new];
    rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    for (unsigned i = 0; i < _passSize; i++)
    {
        id<MTLRenderCommandEncoder> rce = nil;
        
        BOOL backBuffer = (_pass[i].rt.view == nil);
        
        if (backBuffer)
        {
            rce = ctx.rce;
        }
        else
        {
            rpd.colorAttachments[0].texture = _pass[i].rt.view;
            rce = [cb renderCommandEncoderWithDescriptor:rpd];
        }
        
#if DEBUG && METAL_DEBUG
        rce.label = [NSString stringWithFormat:@"pass %d", i];
#endif
        
        [rce setRenderPipelineState:_pass[i]._state];
        rce.label = _pass[i]._state.label;
        
        _pass[i].frame_count = (uint32_t)_frameCount;
        if (_pass[i].frame_count_mod)
            _pass[i].frame_count %= _pass[i].frame_count_mod;
        
        for (unsigned j = 0; j < SLANG_CBUFFER_MAX; j++)
        {
            id<MTLBuffer> buffer = _pass[i].buffers[j];
            cbuffer_sem_t *buffer_sem = &_pass[i].semantics.cbuffers[j];
            
            if (buffer_sem->stage_mask && buffer_sem->uniforms)
            {
                void *data = buffer.contents;
                uniform_sem_t *uniform = buffer_sem->uniforms;
                
                while (uniform->size)
                {
                    if (uniform->data)
                        memcpy((uint8_t *)data + uniform->offset, uniform->data, uniform->size);
                    uniform++;
                }
                
                if (buffer_sem->stage_mask & SLANG_STAGE_VERTEX_MASK)
                    [rce setVertexBuffer:buffer offset:0 atIndex:buffer_sem->binding];
                
                if (buffer_sem->stage_mask & SLANG_STAGE_FRAGMENT_MASK)
                    [rce setFragmentBuffer:buffer offset:0 atIndex:buffer_sem->binding];
                [buffer didModifyRange:NSMakeRange(0, buffer.length)];
            }
        }
        
        __unsafe_unretained id<MTLTexture> textures[SLANG_NUM_BINDINGS] = {NULL};
        id<MTLSamplerState> samplers[SLANG_NUM_BINDINGS] = {NULL};
        
        texture_sem_t *texture_sem = _pass[i].semantics.textures;
        while (texture_sem->stage_mask)
        {
            int binding = texture_sem->binding;
            id<MTLTexture> tex = (__bridge id<MTLTexture>)*(void **)texture_sem->texture_data;
            textures[binding] = tex;
            samplers[binding] = _samplers[texture_sem->filter][texture_sem->wrap];
            texture_sem++;
        }
        
        if (backBuffer)
        {
            [rce setViewport:_outputFrame.viewport];
        }
        else
        {
            [rce setViewport:_pass[i].viewport];
        }
        
        [rce setFragmentTextures:textures withRange:NSMakeRange(0, SLANG_NUM_BINDINGS)];
        [rce setFragmentSamplerStates:samplers withRange:NSMakeRange(0, SLANG_NUM_BINDINGS)];
        [rce setVertexBytes:_vertex length:sizeof(_vertex) atIndex:4];
        [rce drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        
        if (!backBuffer)
        {
            [rce endEncoding];
        }
    }
    
    // if the last view is nil, the last pass of the shader pipeline rendered to the
    // layer's render target
    return _pass[_passSize-1].rt.view != nil;
}

- (void)_updateRenderTargets
{
    if (!_shader || !_resizeRenderTargets) return;
    
    // release existing targets
    for (int i = 0; i < _passSize; i++)
    {
        _pass[i].rt.view = nil;
        _pass[i].feedback.view = nil;
        bzero(&_pass[i].rt.size_data, sizeof(_pass[i].rt.size_data));
        bzero(&_pass[i].feedback.size_data, sizeof(_pass[i].feedback.size_data));
    }
    
    NSInteger width = _size.width, height = _size.height;
    
    OEIntSize size = _viewport.view.size;
    
    for (unsigned i = 0; i < _passSize; i++)
    {
        ShaderPass *pass = _shader.passes[i];
        
        if (pass.valid)
        {
            switch (pass.scaleX)
            {
                case ShaderPassScaleInput:
                    width *= pass.scale.width;
                    break;
                    
                case ShaderPassScaleViewport:
                    width = (NSInteger)(size.width * pass.scale.width);
                    break;
                    
                case ShaderPassScaleAbsolute:
                    width = pass.size.width;
                    break;
                    
                default:
                    break;
            }
            
            if (!width)
                width = size.width;
            
            switch (pass.scaleY)
            {
                case ShaderPassScaleInput:
                    height *= pass.scale.height;
                    break;
                    
                case ShaderPassScaleViewport:
                    height = (NSInteger)(size.height * pass.scale.height);
                    break;
                    
                case ShaderPassScaleAbsolute:
                    height = pass.size.width;
                    break;
                    
                default:
                    break;
            }
            
            if (!height)
                height = size.height;
        }
        else if (i == (_passSize - 1))
        {
            width = size.width;
            height = size.height;
        }
        
        NSLog(@"updating framebuffer pass %d, size %lu x %lu", i, width, height);
        
        MTLPixelFormat fmt = SelectOptimalPixelFormat(glslang_format_to_metal(_pass[i].semantics.format));
        if ((i != (_passSize - 1)) ||
            (width != size.width) || (height != size.height) ||
            fmt != MTLPixelFormatBGRA8Unorm)
        {
            _pass[i].viewport.width = width;
            _pass[i].viewport.height = height;
            _pass[i].viewport.znear = 0.0;
            _pass[i].viewport.zfar = 1.0;
            
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:false];
            td.storageMode = MTLStorageModePrivate;
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            [self _initTexture:&_pass[i].rt withDescriptor:td];
            
            if (pass.isFeedback)
            {
                [self _initTexture:&_pass[i].feedback withDescriptor:td];
            }
        }
        else
        {
            _pass[i].rt.size_data.x = width;
            _pass[i].rt.size_data.y = height;
            _pass[i].rt.size_data.z = 1.0f / width;
            _pass[i].rt.size_data.w = 1.0f / height;
        }
    }
    
    _resizeRenderTargets = NO;
}

- (void)_freeShaderResources
{
    for (int i = 0; i < kMaxShaderPasses; i++)
    {
        _pass[i].rt.view = nil;
        _pass[i].feedback.view = nil;
        bzero(&_pass[i].rt.size_data, sizeof(_pass[i].rt.size_data));
        bzero(&_pass[i].feedback.size_data, sizeof(_pass[i].feedback.size_data));
        
        _pass[i]._state = nil;
        
        for (unsigned j = 0; j < SLANG_CBUFFER_MAX; j++)
        {
            _pass[i].buffers[j] = nil;
        }
    }
    
    for (int i = 0; i < kMaxTextures; i++)
    {
        _luts[i].view = nil;
    }
    
    _historySize = 0;
    _passSize    = 0;
    _lutSize     = 0;
}

- (BOOL)setShaderFromPath:(NSString *)path context:(id<OEMTLRenderContext>)ctx
{
    [self _freeShaderResources];
    
    SlangShader *ss = [[SlangShader alloc] initFromPath:path];
    if (ss == nil) {
        return NO;
    }
    
    _historySize = ss.historySize;
    _passSize    = ss.passes.count;
    _lutSize     = ss.luts.count;
    
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = YES;
    
    @try
    {
        texture_t *source = &_outputFrame.texture[0];
        for (unsigned i = 0; i < _passSize; source = &_pass[i++].rt)
        {
            ShaderPass *pass = ss.passes[i];
            _pass[i].hasFeedback = pass.isFeedback;
            _pass[i].frame_count_mod = (uint32_t)pass.frameCountMod;
            
            matrix_float4x4 *mvp = (i == _passSize-1) ? &ctx.uniforms->projectionMatrix : &ctx.uniformsNoRotate->projectionMatrix;
            
            /* clang-format off */
            semantics_map_t semantics_map = {
                {
                    /* Original */
                    {&_outputFrame.texture[0].view, 0,
                        &_outputFrame.texture[0].size_data, 0},
                    
                    /* Source */
                    {&source->view, 0,
                        &source->size_data, 0},
                    
                    /* OriginalHistory */
                    {&_outputFrame.texture[0].view, sizeof(*_outputFrame.texture),
                        &_outputFrame.texture[0].size_data, sizeof(*_outputFrame.texture)},
                    
                    /* PassOutput */
                    {&_pass[0].rt.view, sizeof(*_pass),
                        &_pass[0].rt.size_data, sizeof(*_pass)},
                    
                    /* PassFeedback */
                    {&_pass[0].feedback.view, sizeof(*_pass),
                        &_pass[0].feedback.size_data, sizeof(*_pass)},
                    
                    /* User */
                    {&_luts[0].view, sizeof(*_luts),
                        &_luts[0].size_data, sizeof(*_luts)},
                },
                {
                    mvp,                        /* MVP */
                    &_pass[i].rt.size_data,     /* OutputSize */
                    &_outputFrame.output_size,  /* FinalViewportSize */
                    &_pass[i].frame_count,      /* FrameCount */
                }
            };
            /* clang-format on */
            
            NSString *vs_src = nil;
            NSString *fs_src = nil;
            
            if (![pass buildMetalVersion:20000
                               semantics:&semantics_map
                           passSemantics:&_pass[i].semantics vertex:&vs_src
                                fragment:&fs_src]) {
                return NO;
            }
            
#ifdef DEBUG
            bool save_msl = false;
#else
            bool save_msl = false;
#endif
            // vertex descriptor
            @try
            {
                MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
                vd.attributes[0].offset = offsetof(Vertex, position);
                vd.attributes[0].format = MTLVertexFormatFloat4;
                vd.attributes[0].bufferIndex = 4;
                vd.attributes[1].offset = offsetof(Vertex, texCoord);
                vd.attributes[1].format = MTLVertexFormatFloat2;
                vd.attributes[1].bufferIndex = 4;
                vd.layouts[4].stride = sizeof(Vertex);
                vd.layouts[4].stepFunction = MTLVertexStepFunctionPerVertex;
                
                MTLRenderPipelineDescriptor *psd = [MTLRenderPipelineDescriptor new];
                psd.label = [NSString stringWithFormat:@"pass %d", i];
                
                MTLRenderPipelineColorAttachmentDescriptor *ca = psd.colorAttachments[0];
                
                ca.pixelFormat = SelectOptimalPixelFormat(glslang_format_to_metal(_pass[i].semantics.format));
                ca.blendingEnabled = NO;
                ca.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                
                psd.sampleCount = 1;
                psd.vertexDescriptor = vd;
                
                NSError *err;
                id<MTLLibrary> lib = [_device newLibraryWithSource:vs_src options:options error:&err];
                if (err != nil)
                {
                    if (lib == nil)
                    {
                        save_msl = true;
                        NSLog(@"unable to compile vertex shader: %@", err.localizedDescription);
                        return NO;
                    }
#if DEBUG_SHADER
                    NSLog(@"warnings compiling vertex shader: %@", err.localizedDescription);
#endif
                }
                
                psd.vertexFunction = [lib newFunctionWithName:@"main0"];
                
                lib = [_device newLibraryWithSource:fs_src options:nil error:&err];
                if (err != nil)
                {
                    if (lib == nil)
                    {
                        save_msl = true;
                        NSLog(@"unable to compile fragment shader: %@", err.localizedDescription);
                        return NO;
                    }
#if DEBUG_SHADER
                    NSLog(@"warnings compiling fragment shader: %@", err.localizedDescription);
#endif
                }
                psd.fragmentFunction = [lib newFunctionWithName:@"main0"];
                
                _pass[i]._state = [_device newRenderPipelineStateWithDescriptor:psd error:&err];
                if (err != nil)
                {
                    save_msl = true;
                    NSLog(@"error creating pipeline state for pass %d: %@", i, err.localizedDescription);
                    return NO;
                }
                
                for (unsigned j = 0; j < SLANG_CBUFFER_MAX; j++)
                {
                    unsigned int size = _pass[i].semantics.cbuffers[j].size;
                    if (size == 0)
                    {
                        continue;
                    }
                    
                    id<MTLBuffer> buf = [_device newBufferWithLength:size options:MTLResourceStorageModeManaged];
                    _pass[i].buffers[j] = buf;
                }
            }
            @finally
            {
                if (save_msl)
                {
                    NSString *basePath = [pass.path stringByDeletingPathExtension];
                    
                    NSLog(@"saving metal shader files to %@", basePath);
                    
                    NSError *err = nil;
                    [vs_src writeToFile:[basePath stringByAppendingPathExtension:@"vs.metal"]
                             atomically:NO
                               encoding:NSStringEncodingConversionAllowLossy
                                  error:&err];
                    if (err != nil)
                    {
                        NSLog(@"unable to save vertex shader source: %d: %@", i, err.localizedDescription);
                    }
                    
                    err = nil;
                    [fs_src writeToFile:[basePath stringByAppendingPathExtension:@"fs.metal"]
                             atomically:NO
                               encoding:NSStringEncodingConversionAllowLossy
                                  error:&err];
                    if (err != nil)
                    {
                        NSLog(@"unable to save fragment shader source: %d: %@", i, err.localizedDescription);
                    }
                }
            }
        }
        
        NSDictionary<MTKTextureLoaderOption, id> *opts = @{
                                                           MTKTextureLoaderOptionGenerateMipmaps: @YES,
                                                           MTKTextureLoaderOptionAllocateMipmaps: @YES,
                                                           };
        
        for (unsigned i = 0; i < _lutSize; i++)
        {
            ShaderLUT *lut = ss.luts[i];
            
            NSError *err;
            id<MTLTexture> t = [_loader newTextureWithContentsOfURL:[NSURL fileURLWithPath:lut.path] options:opts error:&err];
            if (err != nil) {
                NSLog(@"unable to load LUT texture at path '%@': %@", lut.path, err);
                continue;
            }
            
            [self _initTexture:&_luts[i] withTexture:t];
        }
        
        _shader = ss;
        ss  = nil;
    }
    @finally
    {
        if (ss)
        {
            [self _freeShaderResources];
        }
    }
    
    _resizeRenderTargets = YES;
    init_history = YES;
    
    return YES;
}

@end

MTLPixelFormat glslang_format_to_metal(glslang_format fmt)
{
#undef FMT2
#define FMT2(x, y) case SLANG_FORMAT_##x: return MTLPixelFormat##y
    
    switch (fmt)
    {
            FMT2(R8_UNORM, R8Unorm);
            FMT2(R8_SINT, R8Sint);
            FMT2(R8_UINT, R8Uint);
            FMT2(R8G8_UNORM, RG8Unorm);
            FMT2(R8G8_SINT, RG8Sint);
            FMT2(R8G8_UINT, RG8Uint);
            FMT2(R8G8B8A8_UNORM, RGBA8Unorm);
            FMT2(R8G8B8A8_SINT, RGBA8Sint);
            FMT2(R8G8B8A8_UINT, RGBA8Uint);
            FMT2(R8G8B8A8_SRGB, RGBA8Unorm_sRGB);
            
            FMT2(A2B10G10R10_UNORM_PACK32, RGB10A2Unorm);
            FMT2(A2B10G10R10_UINT_PACK32, RGB10A2Uint);
            
            FMT2(R16_UINT, R16Uint);
            FMT2(R16_SINT, R16Sint);
            FMT2(R16_SFLOAT, R16Float);
            FMT2(R16G16_UINT, RG16Uint);
            FMT2(R16G16_SINT, RG16Sint);
            FMT2(R16G16_SFLOAT, RG16Float);
            FMT2(R16G16B16A16_UINT, RGBA16Uint);
            FMT2(R16G16B16A16_SINT, RGBA16Sint);
            FMT2(R16G16B16A16_SFLOAT, RGBA16Float);
            
            FMT2(R32_UINT, R32Uint);
            FMT2(R32_SINT, R32Sint);
            FMT2(R32_SFLOAT, R32Float);
            FMT2(R32G32_UINT, RG32Uint);
            FMT2(R32G32_SINT, RG32Sint);
            FMT2(R32G32_SFLOAT, RG32Float);
            FMT2(R32G32B32A32_UINT, RGBA32Uint);
            FMT2(R32G32B32A32_SINT, RGBA32Sint);
            FMT2(R32G32B32A32_SFLOAT, RGBA32Float);
            
        case SLANG_FORMAT_UNKNOWN:
        default:
            break;
    }
#undef FMT2
    return MTLPixelFormatInvalid;
}

MTLPixelFormat SelectOptimalPixelFormat(MTLPixelFormat fmt)
{
    switch (fmt)
    {
        case MTLPixelFormatInvalid: /* fallthrough */
        case MTLPixelFormatRGBA8Unorm:
            return MTLPixelFormatBGRA8Unorm;
            
        case MTLPixelFormatRGBA8Unorm_sRGB:
            return MTLPixelFormatBGRA8Unorm_sRGB;
            
        default:
            return fmt;
    }
}
