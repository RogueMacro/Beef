#pragma once

#include "Common.h"
#include "util/Dictionary.h"

#ifdef BF_PLATFORM_OPENGL_ES2
#include <SDL3/SDL_opengles2.h>
#else
#include <SDL3/SDL_opengl.h>
#endif

#include "gfx/Shader.h"
#include "gfx/Texture.h"
#include "gfx/RenderDevice.h"
#include "gfx/DrawLayer.h"

struct SDL_Window;
struct SDL_GLContextState;
typedef struct SDL_GLContextState* SDL_GLContext;

NS_BF_BEGIN;

class BFApp;
class GLRenderDevice;

class GLTexture : public Texture
{
public:
	GLRenderDevice*			mRenderDevice;
	GLuint					mGLTexture;
	GLuint					mGLTexture2;
	ImageData*				mImageData;

	// Render targets only. Framebuffer objects aren't shared between contexts, so there's one per
	// context the target gets bound in; the texture and depth renderbuffer are shared.
	bool					mIsRenderTarget;
	GLuint					mGLDepthBuffer;
	bool					mGLDepthHasStencil;
	Dictionary<SDL_GLContext, GLuint> mGLFramebufferMap;

public:
	GLTexture();
	virtual ~GLTexture();

	bool					BindFramebuffer(GLenum target);

	virtual void			PhysSetAsTarget() override;
	virtual void			Blt(ImageData* imageData, int x, int y) override;
	virtual void			SetBits(int destX, int destY, int destWidth, int destHeight, int srcPitch, uint32 *bits) override;
	virtual void			GetBits(int srcX, int srcY, int srcWidth, int srcHeight, int destPitch, uint32* bits) override;
};

class GLShaderParam : public ShaderParam
{
public:
	GLint					mGLVariable;

public:
	GLShaderParam();
	~GLShaderParam();

	virtual void			SetTexture(Texture* texture) override;
	virtual void			SetFloat4(float x, float y, float z, float w) override;
};

typedef Dictionary<String, GLShaderParam*> GLShaderParamMap;

class GLShader : public Shader
{
public:
	GLuint				mGLVertexShader;
	GLuint				mGLFragmentShader;
	GLuint				mGLProgram;
	GLint				mAttribPosition;
	GLint				mAttribTexCoord0;
	GLint				mAttribColor;
	GLint				mAttribTex0;
	GLint				mAttribTex1;
	GLint				mScreenUniformLoc;

	GLShaderParamMap	mParamsMap;

public:
	GLShader();
	~GLShader();

	virtual ShaderParam*	GetShaderParam(const StringImpl& name) override;
};

class GLSetTextureCmd : public RenderCmd
{
public:
	int						mTextureIdx;
	Texture*				mTexture;

public:
	virtual void Render(RenderDevice* renderDevice, RenderWindow* renderWindow) override;
};


class GLDrawBatch : public DrawBatch
{
public:


public:
	GLDrawBatch();
	~GLDrawBatch();

	//virtual void			Lock();
	virtual void			Render(RenderDevice* renderDevice, RenderWindow* renderWindow) override;
};

class GLDrawLayer : public DrawLayer
{
public:
	virtual DrawBatch*		CreateDrawBatch();
	virtual RenderCmd*		CreateSetTextureCmd(int textureIdx, Texture* texture) override;
	virtual void			SetShaderConstantData(int usageIdx, int slotIdx, void* constData, int size) override;

public:
	GLDrawLayer();
	~GLDrawLayer();
};

class GLRenderWindow : public RenderWindow
{
public:
	SDL_Window*				mSDLWindow;
	SDL_GLContext			mGLContext;
	GLRenderDevice*			mRenderDevice;
	bool					mResizePending;
	int						mPendingWidth;
	int						mPendingHeight;
	float					mRefreshRate;

public:
	virtual void			PhysSetAsTarget();

public:
	GLRenderWindow(GLRenderDevice* renderDevice, SDL_Window* sdlWindow, SDL_GLContext glContext);
	virtual ~GLRenderWindow();

	void					SetAsTarget() override;
	void					Resized() override;
	void					Present() override;

	void					CopyBitsTo(uint32* dest, int width, int height);
	float					GetRefreshRate() override;
};

class GLRenderDevice : public RenderDevice
{
public:
	Dictionary<SDL_GLContext, GLuint> mGLVAOMap; // VAOs aren't shared between contexts
	GLuint					mGLVertexBuffer;
	GLuint					mGLIndexBuffer;
	GLuint					mBlankTexture;
	GLShader*				mCurShader;

	bool					mHasVSync;

	// Size of the bound target, and whether it's a texture. Texture targets are drawn with a flipped
	// projection so their first row is the image's top, like uploaded textures. Dirty forces the next
	// draw batch to reapply its render state (projection, scissor) for a new target.
	int						mPhysTargetWidth;
	int						mPhysTargetHeight;
	bool					mPhysTargetIsTexture;
	bool					mPhysTargetDirty;

    GLDrawBatch*            mFreeBatchHead;

public:
	//virtual void			PhysSetAdditive(bool additive);
	//virtual void			PhysSetShader(Shader* shaderPass);
	virtual void			PhysSetRenderWindow(RenderWindow* renderWindow);
	virtual void			PhysSetRenderState(RenderState* renderState) override;
	virtual void			PhysSetRenderTarget(Texture* renderTarget) override;
	void					ResetContextState();
	void					SetPhysTarget(int width, int height, bool isTexture);

public:
	GLRenderDevice();
	virtual ~GLRenderDevice();
	bool					Init(BFApp* app) override;

	void					FrameStart() override;
	void					FrameEnd() override;

	Texture*				LoadTexture(ImageData* imageData, int flags) override;
	Shader*					LoadShader(const StringImpl& fileName, VertexDefinition* vertexDefinition, const StringImpl& entrySuffix, int shaderFlags) override;
	Texture*				CreateRenderTarget(int width, int height, int flags, int sampleCount) override;

	virtual Texture*		CreateDynTexture(int width, int height) override;
	virtual void			SetRenderState(RenderState* renderState) override;

	/*void					SetShader(Shader* shader) override;
	virtual void			SetClip(float x, float y, float width, float height) override;
	virtual void			DisableClip() override;*/
};

NS_BF_END;
