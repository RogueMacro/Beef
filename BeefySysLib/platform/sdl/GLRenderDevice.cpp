#include "GLRenderDevice.h"
#include "BFApp.h"
#include "SdlBFApp.h"
#include "BFWindow.h"
#include "img/ImageData.h"
#include "util/PerfTimer.h"
#include <SDL3/SDL_video.h>

USING_NS_BF;

#ifndef NOT_IMPL
#define NOT_IMPL throw "Not implemented"
#endif

//#pragma comment(lib, "SDL3.lib")

#ifdef _WIN32
#ifdef BF_PLATFORM_OPENGL_ES2
#pragma comment(lib, "libEGL.lib")
#pragma comment(lib, "libGLESv2.lib")
#else
#pragma comment(lib, "opengl32.lib")
#endif
#endif

/*#if SDL_VIDEO_DRIVER_WINDOWS
#define APIENTRYP __stdcall *
#elif defined BF_PLATFORM_OPENGL_ES2
#define APIENTRYP *
#endif*/


#define GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG 0x8C00
#define GL_COMPRESSED_RGB_PVRTC_2BPPV1_IMG 0x8C01
#define GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG 0x8C02
#define GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG 0x8C03

#if defined BF_PLATFORM_OPENGL_ES2
#define APIENTRYP BF_CALLTYPE *
#endif

extern void* (SDLCALL* bf_SDL_GL_GetProcAddress)(const char* proc);
extern bool (SDLCALL* bf_SDL_GetWindowSizeInPixels)(SDL_Window* window, int* w, int* h);
extern bool (SDLCALL* bf_SDL_GL_SwapWindow)(SDL_Window* window);
extern bool (SDLCALL* bf_SDL_GL_MakeCurrent)(SDL_Window* window, SDL_GLContext context);
extern SDL_GLContext (SDLCALL* bf_SDL_GL_GetCurrentContext)();
extern const char* (SDLCALL* bf_SDL_GetError)(void);

extern SDL_DisplayID (SDLCALL* bf_SDL_GetDisplayForWindow)(SDL_Window *window);
extern const SDL_DisplayMode* (SDLCALL* bf_SDL_GetCurrentDisplayMode)(SDL_DisplayID displayID);

static GLenum (APIENTRYP bf_glGetError)();
static void (APIENTRYP bf_glReadPixels)(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, GLvoid* pixels);
static void (APIENTRYP bf_glActiveTexture)(GLenum texture);
static void (APIENTRYP bf_glGenVertexArrays)(GLsizei n, GLuint* buffers);
static void (APIENTRYP bf_glBindVertexArray)(GLenum target);
static void (APIENTRYP bf_glGenBuffers)(GLsizei n, GLuint *buffers);
static void (APIENTRYP bf_glBindBuffer)(GLenum target, GLuint buffer);
static void (APIENTRYP bf_glBufferData)(GLenum target, GLsizeiptr size, const GLvoid *data, GLenum usage);
static void (APIENTRYP bf_glDeleteBuffers)(GLsizei n, const GLuint *buffers);
static GLvoid* (APIENTRYP bf_glMapBuffer)(GLenum target, GLenum access);
static GLboolean (APIENTRYP bf_glUnmapBuffer)(GLenum target);
static void (APIENTRYP bf_glGetBufferParameteriv)(GLenum target, GLenum pname, GLint *params);

static void (APIENTRYP bf_glColorPointer)(GLint size, GLenum type, GLsizei stride, const GLvoid *pointer);
static void (APIENTRYP bf_glDrawArrays)(GLenum mode, GLint first, GLsizei count);
static void (APIENTRYP bf_glEdgeFlagPointer)(GLsizei stride, const GLboolean *pointer);
static void (APIENTRYP bf_glGetPointerv)(GLenum pname, GLvoid* *params);
static void (APIENTRYP bf_glIndexPointer)(GLenum type, GLsizei stride, const GLvoid *pointer);
static void (APIENTRYP bf_glNormalPointer)(GLenum type, GLsizei stride, const GLvoid *pointer);
static void (APIENTRYP bf_glTexCoordPointer)(GLint size, GLenum type, GLsizei stride, const GLvoid *pointer);
static void (APIENTRYP bf_glVertexPointer)(GLint size, GLenum type, GLsizei stride, const GLvoid *pointer);
static void (APIENTRYP bf_glVertexAttribPointer)(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const GLvoid *pointer);
static void (APIENTRYP bf_glDrawElements)(GLenum mode, GLsizei count, GLenum type, const GLvoid * indices);

static void (APIENTRYP bf_glAttachShader)(GLuint program, GLuint shader);
static void (APIENTRYP bf_glBindAttribLocation)(GLuint program, GLuint index, const GLchar *name);
static void (APIENTRYP bf_glCompileShader)(GLuint shader);
static GLuint (APIENTRYP bf_glCreateProgram)(void);
static GLuint (APIENTRYP bf_glCreateShader)(GLenum type);
static void (APIENTRYP bf_glDeleteProgram)(GLuint program);
static void (APIENTRYP bf_glDeleteShader)(GLuint shader);
static void (APIENTRYP bf_glDetachShader)(GLuint program, GLuint shader);
static void (APIENTRYP bf_glDisableVertexAttribArray)(GLuint index);
static void (APIENTRYP bf_glEnableVertexAttribArray)(GLuint index);
static void (APIENTRYP bf_glGetActiveAttrib)(GLuint program, GLuint index, GLsizei bufSize, GLsizei *length, GLint *size, GLenum *type, GLchar *name);
static void (APIENTRYP bf_glGetActiveUniform)(GLuint program, GLuint index, GLsizei bufSize, GLsizei *length, GLint *size, GLenum *type, GLchar *name);
static void (APIENTRYP bf_glGetAttachedShaders)(GLuint program, GLsizei maxCount, GLsizei *count, GLuint *obj);
static GLint (APIENTRYP bf_glGetAttribLocation)(GLuint program, const GLchar *name);
static void (APIENTRYP bf_glGetProgramiv)(GLuint program, GLenum pname, GLint *params);
static void (APIENTRYP bf_glGetProgramInfoLog)(GLuint program, GLsizei bufSize, GLsizei *length, GLchar *infoLog);
static void (APIENTRYP bf_glGetShaderiv)(GLuint shader, GLenum pname, GLint *params);
static void (APIENTRYP bf_glGetShaderInfoLog)(GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *infoLog);
static void (APIENTRYP bf_glGetShaderSource)(GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *source);
static GLint (APIENTRYP bf_glGetUniformLocation)(GLuint program, const GLchar *name);
static void (APIENTRYP bf_glGetUniformfv)(GLuint program, GLint location, GLfloat *params);
static void (APIENTRYP bf_glGetUniformiv)(GLuint program, GLint location, GLint *params);
static void (APIENTRYP bf_glGetVertexAttribfv)(GLuint index, GLenum pname, GLfloat *params);
static void (APIENTRYP bf_glGetVertexAttribiv)(GLuint index, GLenum pname, GLint *params);
static void (APIENTRYP bf_glGetVertexAttribPointerv)(GLuint index, GLenum pname, GLvoid* *pointer);
static GLboolean (APIENTRYP bf_glIsProgram)(GLuint program);
static GLboolean (APIENTRYP bf_glIsShader)(GLuint shader);
static void (APIENTRYP bf_glLinkProgram)(GLuint program);
static void (APIENTRYP bf_glShaderSource)(GLuint shader, GLsizei count, const GLchar* *string, const GLint *length);
static void (APIENTRYP bf_glUseProgram)(GLuint program);
static void (APIENTRYP bf_glUniform1f)(GLint location, GLfloat v0);
static void (APIENTRYP bf_glUniform2f)(GLint location, GLfloat v0, GLfloat v1);
static void (APIENTRYP bf_glUniform3f)(GLint location, GLfloat v0, GLfloat v1, GLfloat v2);
static void (APIENTRYP bf_glUniform4f)(GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3);
static void (APIENTRYP bf_glUniformMatrix4fv)(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
static void (APIENTRYP bf_glGetObjectParameterivARB)(GLint obj, GLenum pname, GLint *params);

static void (APIENTRYP bf_glCompressedTexImage2D)(GLenum target, GLint level, GLenum internalformat, GLsizei width, GLsizei height, GLint border, GLsizei imageSize, const GLvoid *data);
static  void (APIENTRYP bf_glClientActiveTexture)(GLenum texture);

static void (APIENTRYP bf_glGenTextures)(GLsizei n, GLuint *textures);
static void (APIENTRYP bf_glBindTexture)(GLenum target, GLuint texture);
static void (APIENTRYP bf_glPixelStorei)(GLenum pname, GLint param);
static void (APIENTRYP bf_glTexImage2D)(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void *pixels);
static void (APIENTRYP bf_glTexParameteri)(GLenum target, GLenum pname, GLint param);
static void (APIENTRYP bf_glDisable)(GLenum cap);
static void (APIENTRYP bf_glEnable)(GLenum cap);
static void (APIENTRYP bf_glCullFace)(GLenum mode);
static void (APIENTRYP bf_glDepthFunc)(GLenum mode);
static void (APIENTRYP bf_glDepthMask)(GLboolean flag);
static void (APIENTRYP bf_glPolygonMode)(GLenum face, GLenum mode);
static void (APIENTRYP bf_glBlendFunc)(GLenum sfactor, GLenum dfactor);
static void (APIENTRYP bf_glScissor)(GLint x, GLint y, GLsizei width, GLsizei height);
static void (APIENTRYP bf_glViewport)(GLint x, GLint y, GLsizei width, GLsizei height);
static void (APIENTRYP bf_glFramebufferTexture)(GLenum target, GLenum attachment, GLuint texture, GLint level);
static void (APIENTRYP bf_glDrawBuffers)(GLsizei n, const GLenum *bufs);
static GLenum (APIENTRYP bf_glCheckFramebufferStatus)(GLenum target);
static void (APIENTRYP bf_glTexSubImage2D)(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels);
static void (APIENTRYP bf_glBindFramebuffer)(GLenum target, GLuint framebuffer);
static void (APIENTRYP bf_glGenFramebuffers)(GLsizei n, GLuint* framebuffers);
static void (APIENTRYP bf_glDeleteFramebuffers)(GLsizei n, const GLuint* framebuffers);
static void (APIENTRYP bf_glGenRenderbuffers)(GLsizei n, GLuint* renderbuffers);
static void (APIENTRYP bf_glDeleteRenderbuffers)(GLsizei n, const GLuint* renderbuffers);
static void (APIENTRYP bf_glBindRenderbuffer)(GLenum target, GLuint renderbuffer);
static void (APIENTRYP bf_glRenderbufferStorage)(GLenum target, GLenum internalformat, GLsizei width, GLsizei height);
static void (APIENTRYP bf_glFramebufferRenderbuffer)(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
static void (APIENTRYP bf_glDeleteTextures)(GLsizei n, const GLuint* textures);
static void (APIENTRYP bf_glFrontFace)(GLenum mode);
static void (APIENTRYP bf_glGetIntegerv)(GLenum pname, GLint* data);
static void (APIENTRYP bf_glClearColor)(GLclampf red, GLclampf green, GLclampf blue, GLclampf alpha);
static void (APIENTRYP bf_glClearDepth)(GLdouble depth);
static void (APIENTRYP bf_glClear)(GLbitfield mask);

#if !defined BF_PLATFORM_OPENGL_ES2
static void (APIENTRYP bf_glGetVertexAttribdv)(GLuint index, GLenum pname, GLdouble *params);
#endif

enum class DebugSource : uint32
{
	API = 0x8246,
	WindowSystem = 0x8247,
	ShaderCompiler = 0x8248,
	ThirdParty = 0x8249,
	Application = 0x824A,
	Other = 0x824B
};

enum class DebugType : uint32
{
	Error = 0x824C,
	DeprecatedBehavior = 0x824D,
	UndefinedBehavior = 0x824E,
	Portability = 0x824F,
	Performance = 0x8250,
	Other = 0x8251,
	Marker = 0x8268,
};

enum class DebugSeverity : uint32
{
	High = 0x9146,
	Medium = 0x9147,
	Low = 0x9148,
	Notification = 0x826B
};

typedef void(*DEBUGPROC)(DebugSource source, DebugType type, uint32 id, DebugSeverity severity, uint32 length, char* message, void* userParam);
static  void (APIENTRYP bf_glDebugMessageCallback)(DEBUGPROC fn, void* userdata);

static void APIENTRY DebugMessageCallback(DebugSource source, DebugType type, uint32 id, DebugSeverity severity, uint32 length, char* message, void* userParam)
{
	if (type == DebugType::Marker || severity == DebugSeverity::Notification)
		return;

	switch (type)
	{
		case DebugType::Error:
			OutputDebugStr("[Error] ");
			break;
		case DebugType::DeprecatedBehavior:
			OutputDebugStr("[DeprecatedBehavior] ");
			break;

		case DebugType::UndefinedBehavior:
			OutputDebugStr("[UndefinedBehavior] ");
			break;

		case DebugType::Portability:
			OutputDebugStr("[Portability] ");
			break;

		case DebugType::Performance:
			OutputDebugStr("[Performance] ");
			break;

		case DebugType::Other:
			OutputDebugStr("[Other] ");
			break;

		case DebugType::Marker:
			OutputDebugStr("[Marker] ");
			break;
	}

    OutputDebugStr(message);
	OutputDebugStrF(" %d\n", id);
}

///

static int GetPowerOfTwo(int input)
{
	int value = 1;
	while (value < input)
		value <<= 1;
	return value;
}

#define GLFAILED(check) ((hr = (check)) != 0)
#define GLCHECK(check) if ((check) != 0) BF_FATAL("GL call failed")

static void CreateOrthographicOffCenter(float left, float right, float bottom, float top, float zNear, float zFar, float matrix[4][4])
{
	memset(matrix, 0, sizeof(float) * 4 * 4);

	float invRL = 1.0f / (right - left);
	float invTB = 1.0f / (top - bottom);
	float invFN = 1.0f / (zFar - zNear);

	matrix[0][0] = 2.0f * invRL;
	matrix[1][1] = 2.0f * invTB;
	matrix[2][2] = -2.0f * invFN;
	matrix[3][3] = 1.0f;

	matrix[3][0] = -(right + left) * invRL;
	matrix[3][1] = -(top + bottom) * invTB;
	matrix[3][2] = -(zFar + zNear) * invFN;
}

GLShaderParam::GLShaderParam()
{
	mGLVariable = 0;
}

GLShaderParam::~GLShaderParam()
{
}

void GLShaderParam::SetTexture(Texture* texture)
{
	NOT_IMPL;
	//GLTexture* dXTexture = (GLTexture*) texture;
	//GLCHECK(mGLVariable->AsShaderResource()->SetResource(dXTexture->mGLTexture));
}

void GLShaderParam::SetFloat4(float x, float y, float z, float w)
{
	NOT_IMPL;
	//float v[4] = {x, y, z, w};
	//GLCHECK(mGLVariable->AsVector()->SetFloatVector(v));
}

///

GLShader::GLShader()
{
}

GLShader::~GLShader()
{
	for (auto paramKV : mParamsMap)
	{
		delete paramKV.mValue;
	}
}

ShaderParam* GLShader::GetShaderParam(const StringImpl& name)
{
	NOT_IMPL;
	return NULL;
}

///

GLTexture::GLTexture()
{
	mGLTexture = 0;
	mGLTexture2 = 0;
	//mGLRenderTargetView = NULL;
	mRenderDevice = NULL;
	mImageData = NULL;
	mIsRenderTarget = false;
	mGLDepthBuffer = 0;
	mGLDepthHasStencil = false;
}

GLTexture::~GLTexture()
{
	if (mImageData != NULL)
		mImageData->Deref();
	//if (mGLTexture != NULL)
		//mGLTexture->Release();

	if (mIsRenderTarget)
	{
		// A framebuffer name is only meaningful in the context that made it, so only the current
		// context's one can be deleted here; any others leak
		GLuint* framebufferPtr = NULL;
		if (mGLFramebufferMap.TryGetValue(bf_SDL_GL_GetCurrentContext(), &framebufferPtr))
			bf_glDeleteFramebuffers(1, framebufferPtr);
		if (mGLDepthBuffer != 0)
			bf_glDeleteRenderbuffers(1, &mGLDepthBuffer);
		if (mGLTexture != 0)
			bf_glDeleteTextures(1, &mGLTexture);
	}
}

bool GLTexture::BindFramebuffer(GLenum target)
{
	if (!mIsRenderTarget)
		return false;

	GLuint* framebufferPtr = NULL;
	if (mGLFramebufferMap.TryAdd(bf_SDL_GL_GetCurrentContext(), NULL, &framebufferPtr))
	{
		*framebufferPtr = 0;
		bf_glGenFramebuffers(1, framebufferPtr);
		bf_glBindFramebuffer(GL_FRAMEBUFFER, *framebufferPtr);
		bf_glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, mGLTexture, 0);
		if (mGLDepthBuffer != 0)
			bf_glFramebufferRenderbuffer(GL_FRAMEBUFFER, mGLDepthHasStencil ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, mGLDepthBuffer);
		GLenum status = bf_glCheckFramebufferStatus(GL_FRAMEBUFFER);
		if (status != GL_FRAMEBUFFER_COMPLETE)
		{
			OutputDebugStrF("GLTexture: render target framebuffer incomplete (0x%X)\n", status);
			bf_glBindFramebuffer(GL_FRAMEBUFFER, 0);
			bf_glDeleteFramebuffers(1, framebufferPtr);
			mGLFramebufferMap.Remove(bf_SDL_GL_GetCurrentContext());
			return false;
		}
	}

	bf_glBindFramebuffer(target, *framebufferPtr);
	return true;
}

void GLTexture::PhysSetAsTarget()
{
#ifdef BF_PLATFORM_OPENGL_ES2
	NOT_IMPL;
#else
	if (!BindFramebuffer(GL_FRAMEBUFFER))
		return;

	bf_glEnable(GL_BLEND);
	bf_glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
	bf_glViewport(0, 0, (GLsizei)mWidth, (GLsizei)mHeight);
	mRenderDevice->SetPhysTarget(mWidth, mHeight, true);

	if (mWantsClear)
	{
		// glClear honors the scissor and depth mask; the dirty target makes the next batch restore both
		bf_glDisable(GL_SCISSOR_TEST);
		bf_glClearColor(0, 0, 0, 0);
		GLbitfield clearMask = GL_COLOR_BUFFER_BIT;
		if (mGLDepthBuffer != 0)
		{
			bf_glDepthMask(GL_TRUE);
			bf_glClearDepth(1);
			clearMask |= GL_DEPTH_BUFFER_BIT;
			if (mGLDepthHasStencil)
				clearMask |= GL_STENCIL_BUFFER_BIT;
		}
		bf_glClear(clearMask);
		if (mGLDepthBuffer != 0)
			bf_glDepthMask(mRenderDevice->mPhysRenderState->mWriteDepthBuffer ? GL_TRUE : GL_FALSE);

		mHasBeenDrawnTo = true;
		if (mResetClear)
			mWantsClear = false;
	}
#endif
}

void GLTexture::GetBits(int srcX, int srcY, int srcWidth, int srcHeight, int destPitch, uint32* bits)
{
#ifndef BF_PLATFORM_OPENGL_ES2
	if ((srcWidth <= 0) || (srcHeight <= 0) || (bits == NULL))
		return;

	// BindFramebuffer binds both read and draw when it first makes this context's framebuffer
	GLint prevReadFramebuffer = 0;
	GLint prevDrawFramebuffer = 0;
	bf_glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevReadFramebuffer);
	bf_glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDrawFramebuffer);
	if (!BindFramebuffer(GL_READ_FRAMEBUFFER))
	{
		bf_glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prevDrawFramebuffer);
		return;
	}

	// Render targets are stored top row first (see GLRenderDevice::SetPhysTarget), so no flip is needed
	bf_glPixelStorei(GL_PACK_ALIGNMENT, 4);
	bf_glPixelStorei(GL_PACK_ROW_LENGTH, destPitch);
	bf_glReadPixels(srcX, srcY, srcWidth, srcHeight, GL_RGBA, GL_UNSIGNED_BYTE, bits);
	bf_glPixelStorei(GL_PACK_ROW_LENGTH, 0);

	bf_glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prevReadFramebuffer);
	bf_glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prevDrawFramebuffer);
#endif
}

void GLTexture::Blt(ImageData* imageData, int x, int y)
{
	if (mImageData != NULL)
	{
		for (int row = 0; row < imageData->mHeight; row++)
		{
			memcpy(mImageData->mBits + (y + row) * mImageData->mWidth + x,
				imageData->mBits + row * imageData->mWidth, imageData->mWidth * 4);
		}
	}
	else
	{
		bf_glBindTexture(GL_TEXTURE_2D, mGLTexture);
		bf_glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, imageData->mWidth, imageData->mHeight, GL_RGBA, GL_UNSIGNED_BYTE, imageData->mBits);
	}
}

void GLTexture::SetBits(int destX, int destY, int destWidth, int destHeight, int srcPitch, uint32 *bits)
{
	bf_glBindTexture(GL_TEXTURE_2D, mGLTexture);
	bf_glTexSubImage2D(GL_TEXTURE_2D, 0, destX, destY, destWidth, destHeight, GL_RGBA, GL_UNSIGNED_BYTE, bits);
}

///

GLDrawBatch::GLDrawBatch() : DrawBatch()
{

}

GLDrawBatch::~GLDrawBatch()
{
}

extern int gBFDrawBatchCount;

void GLDrawBatch::Render(RenderDevice* renderDevice, RenderWindow* renderWindow)
{
	if (mIdxIdx == 0)
		return;

    gBFDrawBatchCount++;

	GLRenderDevice* glRenderDevice = (GLRenderDevice*) gBFApp->mRenderDevice;
	GLShader* curShader = (GLShader*)mRenderState->mShader;

	GLuint* vaoPtr = NULL;
	if (glRenderDevice->mGLVAOMap.TryAdd(bf_SDL_GL_GetCurrentContext(), NULL, &vaoPtr))
	{
		if (glRenderDevice->mGLVertexBuffer == 0)
		{
			bf_glGenBuffers(1, &glRenderDevice->mGLVertexBuffer);
			bf_glGenBuffers(1, &glRenderDevice->mGLIndexBuffer);
		}

		bf_glBindBuffer(GL_ARRAY_BUFFER, glRenderDevice->mGLVertexBuffer);
		bf_glGenVertexArrays(1, vaoPtr);
		bf_glBindVertexArray(*vaoPtr);

		bf_glEnableVertexAttribArray(curShader->mAttribPosition);
		bf_glVertexAttribPointer(curShader->mAttribPosition, 3, GL_FLOAT, GL_FALSE, sizeof(DefaultVertex3D), (void*)offsetof(DefaultVertex3D, x));
		bf_glEnableVertexAttribArray(curShader->mAttribTexCoord0);
		bf_glVertexAttribPointer(curShader->mAttribTexCoord0, 2, GL_FLOAT, GL_FALSE, sizeof(DefaultVertex3D), (void*)offsetof(DefaultVertex3D, u));
		bf_glEnableVertexAttribArray(curShader->mAttribColor);
		bf_glVertexAttribPointer(curShader->mAttribColor, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(DefaultVertex3D), (void*)offsetof(DefaultVertex3D, color));
	}
    bf_glBindVertexArray(*vaoPtr);
	auto glVertices = (DefaultVertex3D*)mVertices;

	bf_glBindBuffer(GL_ARRAY_BUFFER, glRenderDevice->mGLVertexBuffer);
	bf_glBufferData(GL_ARRAY_BUFFER, mVtxIdx * sizeof(DefaultVertex3D), mVertices, GL_STREAM_DRAW);
	bf_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, glRenderDevice->mGLIndexBuffer);
	bf_glBufferData(GL_ELEMENT_ARRAY_BUFFER, mIdxIdx * sizeof(int16), mIndices, GL_STREAM_DRAW);

	if ((mRenderState != renderDevice->mPhysRenderState) || (glRenderDevice->mPhysTargetDirty))
		renderDevice->PhysSetRenderState(mRenderState);

	bf_glDrawElements(GL_TRIANGLES, mIdxIdx, GL_UNSIGNED_SHORT, NULL);
}

GLDrawLayer::GLDrawLayer()
{
}

GLDrawLayer::~GLDrawLayer()
{
}

DrawBatch* GLDrawLayer::CreateDrawBatch()
{
	return new GLDrawBatch();
}


RenderCmd* GLDrawLayer::CreateSetTextureCmd(int textureIdx, Texture* texture)
{
	GLSetTextureCmd* setTextureCmd = AllocRenderCmd<GLSetTextureCmd>();
	setTextureCmd->mTextureIdx = textureIdx;
	setTextureCmd->mTexture = texture;
	return setTextureCmd;
}

void GLDrawLayer::SetShaderConstantData(int usageIdx, int slotIdx, void* constData, int size)
{
}

void GLRenderDevice::PhysSetRenderWindow(RenderWindow* renderWindow)
{
	mCurRenderTarget = renderWindow;
	mPhysRenderWindow = renderWindow;
	((GLRenderWindow*)renderWindow)->PhysSetAsTarget();
}

void GLRenderDevice::PhysSetRenderTarget(Texture* renderTarget)
{
	mCurRenderTarget = renderTarget;
	renderTarget->PhysSetAsTarget();
}

///

template <typename T>
static void BFGetGLProc(T& proc, const char* name)
{
	proc = (T)bf_SDL_GL_GetProcAddress(name);
}

#define BF_GET_GLPROC(name) BFGetGLProc(bf_##name, #name)

GLRenderWindow::GLRenderWindow(GLRenderDevice* renderDevice, SDL_Window* sdlWindow, SDL_GLContext glContext)
{
	if (bf_glGenBuffers == NULL)
	{
		BF_GET_GLPROC(glGetError);
		BF_GET_GLPROC(glActiveTexture);
		BF_GET_GLPROC(glGenVertexArrays);
		BF_GET_GLPROC(glBindVertexArray);
		BF_GET_GLPROC(glGenBuffers);
		BF_GET_GLPROC(glBindBuffer);
		BF_GET_GLPROC(glBufferData);
		BF_GET_GLPROC(glDeleteBuffers);
		BF_GET_GLPROC(glMapBuffer);
		BF_GET_GLPROC(glUnmapBuffer);
		BF_GET_GLPROC(glGetBufferParameteriv);

		BF_GET_GLPROC(glColorPointer);
		BF_GET_GLPROC(glDrawArrays);
		BF_GET_GLPROC(glEdgeFlagPointer);
		BF_GET_GLPROC(glGetPointerv);
		BF_GET_GLPROC(glIndexPointer);
		BF_GET_GLPROC(glNormalPointer);
		BF_GET_GLPROC(glTexCoordPointer);
		BF_GET_GLPROC(glVertexPointer);
		BF_GET_GLPROC(glDrawElements);
		BF_GET_GLPROC(glVertexAttribPointer);

		BF_GET_GLPROC(glAttachShader);
		BF_GET_GLPROC(glBindAttribLocation);
		BF_GET_GLPROC(glCompileShader);
		BF_GET_GLPROC(glCreateProgram);
		BF_GET_GLPROC(glCreateShader);
		BF_GET_GLPROC(glDeleteProgram);
		BF_GET_GLPROC(glDeleteShader);
		BF_GET_GLPROC(glDetachShader);
		BF_GET_GLPROC(glDisableVertexAttribArray);
		BF_GET_GLPROC(glEnableVertexAttribArray);
		BF_GET_GLPROC(glGetActiveAttrib);
		BF_GET_GLPROC(glGetActiveUniform);
		BF_GET_GLPROC(glGetAttachedShaders);
		BF_GET_GLPROC(glGetAttribLocation);
		BF_GET_GLPROC(glGetProgramiv);
		BF_GET_GLPROC(glGetProgramInfoLog);
		BF_GET_GLPROC(glGetShaderiv);
		BF_GET_GLPROC(glGetShaderInfoLog);
		BF_GET_GLPROC(glGetShaderSource);
		BF_GET_GLPROC(glGetUniformLocation);
		BF_GET_GLPROC(glGetUniformfv);
		BF_GET_GLPROC(glGetUniformiv);
		BF_GET_GLPROC(glGetVertexAttribfv);
		BF_GET_GLPROC(glGetVertexAttribiv);
		BF_GET_GLPROC(glGetVertexAttribPointerv);
		BF_GET_GLPROC(glIsProgram);
		BF_GET_GLPROC(glIsShader);
		BF_GET_GLPROC(glLinkProgram);
		BF_GET_GLPROC(glShaderSource);
		BF_GET_GLPROC(glUseProgram);
		BF_GET_GLPROC(glUniform1f);
		BF_GET_GLPROC(glUniform2f);
		BF_GET_GLPROC(glUniform3f);
		BF_GET_GLPROC(glUniform4f);
		BF_GET_GLPROC(glUniformMatrix4fv);
		BF_GET_GLPROC(glGetObjectParameterivARB);
		BF_GET_GLPROC(glCompressedTexImage2D);
		BF_GET_GLPROC(glClientActiveTexture);
		BF_GET_GLPROC(glGenTextures);
		BF_GET_GLPROC(glBindTexture);
		BF_GET_GLPROC(glPixelStorei);
		BF_GET_GLPROC(glReadPixels);
		BF_GET_GLPROC(glTexImage2D);
		BF_GET_GLPROC(glTexParameteri);
		BF_GET_GLPROC(glDisable);
		BF_GET_GLPROC(glEnable);
		BF_GET_GLPROC(glCullFace);
		BF_GET_GLPROC(glDepthMask);
		BF_GET_GLPROC(glPolygonMode);
		BF_GET_GLPROC(glDepthFunc);
		BF_GET_GLPROC(glBlendFunc);
		BF_GET_GLPROC(glScissor);
		BF_GET_GLPROC(glViewport);
		BF_GET_GLPROC(glFramebufferTexture);
		BF_GET_GLPROC(glDrawBuffers);
		BF_GET_GLPROC(glCheckFramebufferStatus);
		BF_GET_GLPROC(glTexSubImage2D);
		BF_GET_GLPROC(glBindFramebuffer);
		BF_GET_GLPROC(glGenFramebuffers);
		BF_GET_GLPROC(glDeleteFramebuffers);
		BF_GET_GLPROC(glGenRenderbuffers);
		BF_GET_GLPROC(glDeleteRenderbuffers);
		BF_GET_GLPROC(glBindRenderbuffer);
		BF_GET_GLPROC(glRenderbufferStorage);
		BF_GET_GLPROC(glFramebufferRenderbuffer);
		BF_GET_GLPROC(glDeleteTextures);
		BF_GET_GLPROC(glFrontFace);
		BF_GET_GLPROC(glGetIntegerv);
		BF_GET_GLPROC(glClearColor);
		BF_GET_GLPROC(glClearDepth);
		BF_GET_GLPROC(glClear);

#if !defined BF_PLATFORM_OPENGL_ES2
        BF_GET_GLPROC(glGetVertexAttribdv);
#endif

#if defined(_DEBUG) && !defined(BF_PLATFORM_OPENGL_ES2)

		BF_GET_GLPROC(glDebugMessageCallback);
		if (bf_glDebugMessageCallback != NULL)
		{
			bf_glEnable(GL_DEBUG_OUTPUT);
			bf_glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS);
			bf_glDebugMessageCallback(&DebugMessageCallback, NULL);
		}
#endif

	}

#ifndef BF_PLATFORM_OPENGL_ES2
	//glEnableClientState(GL_INDEX_ARRAY);
#endif

	mRefreshRate = 0;
	mSDLWindow = sdlWindow;
	mGLContext = glContext;
	mRenderDevice = renderDevice;
	Resized();

	//bf_glDebugMessageCallback(GL_DebugCallback, NULL);
}

GLRenderWindow::~GLRenderWindow()
{

}

void GLRenderWindow::PhysSetAsTarget()
{
	bool contextChanged = bf_SDL_GL_GetCurrentContext() != mGLContext;
	bf_SDL_GL_MakeCurrent(mSDLWindow, mGLContext);
	if (contextChanged)
		mRenderDevice->ResetContextState();
#ifndef BF_PLATFORM_OPENGL_ES2
	if (mRenderDevice->mPhysTargetIsTexture)
		bf_glBindFramebuffer(GL_FRAMEBUFFER, 0);
#endif

	bf_glEnable(GL_BLEND);
	bf_glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

	if (mResizePending)
	{
		Resized();
	}

	bf_glViewport(0, 0, (GLsizei)mWidth, (GLsizei)mHeight);
	bf_glScissor(0, 0, (GLsizei)mWidth, (GLsizei)mHeight);
	mRenderDevice->SetPhysTarget(mWidth, mHeight, false);

	if (!mHasBeenDrawnTo)
	{
		bf_glClearColor(0, 0, 0, 0);
		bf_glClearDepth(1);
		bf_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	}
	mHasBeenDrawnTo = true;
}

void GLRenderWindow::SetAsTarget()
{
	//TODO: Handle this more elegantly when we actually handle draw layers properly...
	//if (mRenderDevice->mCurRenderTarget != NULL)
		//mRenderDevice->mCurDrawLayer->Flush();

	mHasBeenTargeted = true;
	mRenderDevice->mCurRenderTarget = this;
}

void GLRenderWindow::Resized()
{
	mRenderDevice->mResizeCount++;
	mResizeNum = mRenderDevice->mResizeCount;

	bf_SDL_GetWindowSizeInPixels(mSDLWindow, &mWidth, &mHeight);
	mResizePending = false;
}

void GLRenderWindow::Present()
{
	bf_SDL_GL_SwapWindow(mSDLWindow);
}

void GLRenderWindow::CopyBitsTo(uint32* dest, int width, int height)
{
	mCurDrawLayer->Flush();
	NOT_IMPL;
}

float GLRenderWindow::GetRefreshRate()
{
	if (mRefreshRate == 0)
	{
		SDL_DisplayID displayID = bf_SDL_GetDisplayForWindow(mSDLWindow);
		const SDL_DisplayMode* mode = bf_SDL_GetCurrentDisplayMode(displayID);
		if (mode != NULL)
			mRefreshRate = mode->refresh_rate;
	}

	if (mRefreshRate == 0)
		mRefreshRate = RenderWindow::GetRefreshRate();

	return mRefreshRate;
}

///

GLRenderDevice::GLRenderDevice()
{
	mCurShader = NULL;
	mGLVertexBuffer = 0;
	mGLIndexBuffer = 0;
	mBlankTexture = 0;
    mFreeBatchHead = NULL;
	mPhysTargetWidth = 0;
	mPhysTargetHeight = 0;
	mPhysTargetIsTexture = false;
	mPhysTargetDirty = true;
}

void GLRenderDevice::SetPhysTarget(int width, int height, bool isTexture)
{
	mPhysTargetWidth = width;
	mPhysTargetHeight = height;
	mPhysTargetIsTexture = isTexture;
	mPhysTargetDirty = true;
	// The flipped projection used for texture targets reverses triangle winding
	if (bf_glFrontFace != NULL)
		bf_glFrontFace(isTexture ? GL_CW : GL_CCW);
}

GLRenderDevice::~GLRenderDevice()
{
}

bool GLRenderDevice::Init(BFApp* app)
{
	SdlBFApp* winApp = (SdlBFApp*) app;

	BF_ASSERT(mDefaultRenderState == NULL);
	auto renderState = (RenderState*)CreateRenderState(NULL);

	mDefaultRenderState = renderState;
	mDefaultRenderState->mDepthFunc = DepthFunc_Less;
	mDefaultRenderState->mWriteDepthBuffer = true;
	mPhysRenderState = mDefaultRenderState;

	return true;
}

void GLRenderDevice::FrameStart()
{
	if (mRenderWindowList.IsEmpty())
		return;

	mCurRenderTarget = NULL;
	mPhysRenderWindow = NULL;

	for (auto aRenderWindow : mRenderWindowList)
	{
		aRenderWindow->mHasBeenDrawnTo = false;
		aRenderWindow->mHasBeenTargeted = false;
	}

	bf_glDisable(GL_SCISSOR_TEST);
	bf_glDisable(GL_CULL_FACE);
	bf_glDisable(GL_DEPTH_TEST);
}

// GL state is per-context, so after switching contexts put the new one into the state FrameStart
// establishes, which is what mPhysRenderState is diffed against.
void GLRenderDevice::ResetContextState()
{
	bf_glDisable(GL_SCISSOR_TEST);
	bf_glDisable(GL_CULL_FACE);
	bf_glDisable(GL_DEPTH_TEST);
	bf_glDepthMask(GL_TRUE);
#ifndef BF_PLATFORM_OPENGL_ES2
	bf_glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
#endif
	mPhysRenderState = mDefaultRenderState;
}

void GLRenderDevice::FrameEnd()
{
	for (auto aRenderWindow : mRenderWindowList)
	{
		if (aRenderWindow->mHasBeenTargeted)
		{
			PhysSetRenderWindow(aRenderWindow);
			PhysSetRenderState(mDefaultRenderState);

			for (auto drawLayer : aRenderWindow->mDrawLayerList)
			{
				drawLayer->Flush();
			}

			aRenderWindow->Present();
		}
	}
}

Texture* GLRenderDevice::LoadTexture(ImageData* imageData, int flags)
{
	imageData->mIsAdditive = (flags & TextureFlag_Additive) != 0;
	imageData->PremultiplyAlpha();

	//int w = power_of_two(imageData->mWidth);
	//int h = power_of_two(imageData->mHeight);
	GLTexture* glTexture = new GLTexture();
	glTexture->mRenderDevice = this;
	glTexture->mWidth = imageData->mWidth;
	glTexture->mHeight = imageData->mHeight;
	glTexture->mImageData = imageData;
	glTexture->AddRef();
	imageData->AddRef();

	return glTexture;
}

Shader* GLRenderDevice::LoadShader(const StringImpl& fileName, VertexDefinition* vertexDefinition, const StringImpl& entrySuffix, int shaderFlags)
{
	// entrySuffix unused: the GL path has no per-pass surface variants.
	GLShader* glShader = new GLShader();

	glShader->mVertexSize = sizeof(DefaultVertex3D);
	glShader->mGLVertexShader = bf_glCreateShader(GL_VERTEX_SHADER);
	glShader->mGLFragmentShader = bf_glCreateShader(GL_FRAGMENT_SHADER);

	GLint vertProgramLen = 0;
	GLint fragProgramLen = 0;

#ifdef BF_PLATFORM_OPENGL_ES2
	GLchar* vertProgram = (GLchar*)LoadBinaryData(fileName + "_es.vert", &vertProgramLen);
	GLchar* fragProgram = (GLchar*)LoadBinaryData(fileName + "_es.frag", &fragProgramLen);
#else
	GLchar* vertProgram = (GLchar*)LoadBinaryData(fileName + ".vert", &vertProgramLen);
	GLchar* fragProgram = (GLchar*)LoadBinaryData(fileName + ".frag", &fragProgramLen);
#endif

	if ((vertProgram == NULL) || (fragProgram == NULL))
	{
		delete vertProgram;
		delete fragProgram;
		return NULL;
	}

	int infoLogLen = 0;
	char infoLog[2048];

	bf_glShaderSource(glShader->mGLVertexShader, 1, (const GLchar**)&vertProgram, &vertProgramLen);
	bf_glCompileShader(glShader->mGLVertexShader);
	bf_glGetShaderInfoLog(glShader->mGLVertexShader, 2048, &infoLogLen, infoLog);
	GLint compiled = 0;

	//bf_glGetObjectParameterivARB(glShader->mGLVertexShader, GL_COMPILE_STATUS, &compiled);
    bf_glGetShaderiv(glShader->mGLVertexShader, GL_COMPILE_STATUS, &compiled);
	if (!compiled)
		BF_FATAL(StrFormat("Shader error: %s", infoLog).c_str());

	bf_glShaderSource(glShader->mGLFragmentShader, 1, (const GLchar**)&fragProgram, &fragProgramLen);
	bf_glCompileShader(glShader->mGLFragmentShader);
	bf_glGetShaderInfoLog(glShader->mGLFragmentShader, 2048, &infoLogLen, infoLog);
	compiled = 0;
	//bf_glGetObjectParameterivARB(glShader->mGLFragmentShader, GL_COMPILE_STATUS, &compiled);
    bf_glGetShaderiv(glShader->mGLFragmentShader, GL_COMPILE_STATUS, &compiled);
	if (!compiled)
		BF_FATAL(StrFormat("Shader error: %s", infoLog).c_str());

	glShader->mGLProgram = bf_glCreateProgram();
	bf_glAttachShader(glShader->mGLProgram, glShader->mGLVertexShader);
	bf_glAttachShader(glShader->mGLProgram, glShader->mGLFragmentShader);

	bf_glLinkProgram(glShader->mGLProgram);

	glShader->mAttribPosition = bf_glGetAttribLocation(glShader->mGLProgram, "position");
	glShader->mAttribTexCoord0 = bf_glGetAttribLocation(glShader->mGLProgram, "texCoord0");
	glShader->mAttribColor = bf_glGetAttribLocation(glShader->mGLProgram, "color");
	glShader->mAttribTex0 = bf_glGetUniformLocation(glShader->mGLProgram, "tex");
	glShader->mAttribTex1 = bf_glGetUniformLocation(glShader->mGLProgram, "tex2");
	glShader->mScreenUniformLoc = bf_glGetUniformLocation(glShader->mGLProgram, "screenMatrix");

	return glShader;
}

void GLRenderDevice::PhysSetRenderState(RenderState* renderState)
{
	mCurShader = (GLShader*)renderState->mShader;
	if (mCurShader != NULL)
	{
		bf_glUseProgram(mCurShader->mGLProgram);
		if ((mCurShader->mScreenUniformLoc >= 0) && (mPhysTargetWidth > 0) && (mPhysTargetHeight > 0))
		{
			GLfloat matrix[4][4];
			// Windows: y down from the top. Texture targets: flipped, so row 0 holds the image's top row.
			float top = mPhysTargetIsTexture ? (float)mPhysTargetHeight : 0.0f;
			float bottom = mPhysTargetIsTexture ? 0.0f : (float)mPhysTargetHeight;
			CreateOrthographicOffCenter(0.0f, (float)mPhysTargetWidth, bottom, top, -100.0f, 100.0f, matrix);
			bf_glUniformMatrix4fv(mCurShader->mScreenUniformLoc, 1, false, (float*)matrix);
		}
	}
	mPhysTargetDirty = false;

	if (renderState->mClipped)
	{
		bf_glEnable(GL_SCISSOR_TEST);
		GLint scissorY = (GLint)renderState->mClipRect.y;
		if (!mPhysTargetIsTexture)
			scissorY = mPhysTargetHeight - (GLint)renderState->mClipRect.y - (GLint)renderState->mClipRect.height;
		bf_glScissor((GLint)renderState->mClipRect.x, scissorY,
			(GLsizei)renderState->mClipRect.width, (GLsizei)renderState->mClipRect.height);
	}
	else
	{
		bf_glDisable(GL_SCISSOR_TEST);
	}

	if (renderState->mCullMode != mPhysRenderState->mCullMode)
	{
		switch (renderState->mCullMode)
		{
			case CullMode_None:
				bf_glDisable(GL_CULL_FACE);
				break;
			case CullMode_Front:
				bf_glEnable(GL_CULL_FACE);
				bf_glCullFace(GL_FRONT);
				break;
			case CullMode_Back:
				bf_glEnable(GL_CULL_FACE);
				bf_glCullFace(GL_BACK);
				break;
		}
	}

	if (renderState->mDepthFunc != mPhysRenderState->mDepthFunc)
	{
		bf_glDepthMask(renderState->mWriteDepthBuffer ? GL_TRUE : GL_FALSE);

		switch (renderState->mDepthFunc)
		{
			case DepthFunc_Never:
				bf_glDisable(GL_DEPTH_TEST);
				break;
			case DepthFunc_Less:
				bf_glDepthFunc(GL_LESS);
				bf_glEnable(GL_DEPTH_TEST);
				break;
			case DepthFunc_LessEqual:
				bf_glDepthFunc(GL_LEQUAL);
				bf_glEnable(GL_DEPTH_TEST);
				break;
			case DepthFunc_Equal:
				bf_glDepthFunc(GL_EQUAL);
				bf_glEnable(GL_DEPTH_TEST);
				break;
			case DepthFunc_Greater:
				bf_glDepthFunc(GL_GREATER);
				bf_glEnable(GL_DEPTH_TEST);
				break;
			case DepthFunc_NotEqual:
				bf_glDepthFunc(GL_NOTEQUAL);
				bf_glEnable(GL_DEPTH_TEST);
				break;
			case DepthFunc_GreaterEqual:
				bf_glDepthFunc(GL_GEQUAL);
				bf_glEnable(GL_DEPTH_TEST);
				break;
			case DepthFunc_Always:
				bf_glDepthFunc(GL_ALWAYS);
				bf_glEnable(GL_DEPTH_TEST);
				break;
		}
	}

	if ((renderState->mWireframe != mPhysRenderState->mWireframe))
	{
		if (renderState->mWireframe)
			bf_glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
		else
			bf_glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
	}

	mPhysRenderState = renderState;
}

// Image.RenderTargetFlags bits (DXRenderDevice reads the same values)
enum GLRenderTargetFlags
{
	GLRenderTargetFlag_HighPrecision = 0x4,
	GLRenderTargetFlag_R8 = 0x8,
	GLRenderTargetFlag_F16 = 0x10,
	GLRenderTargetFlag_RG8 = 0x40,
	GLRenderTargetFlag_R16F = 0x80,
	GLRenderTargetFlag_R32Uint = 0x100,
	GLRenderTargetFlag_RG16F = 0x400,
	GLRenderTargetFlag_Depth = 0x800,
	GLRenderTargetFlag_Stencil = 0x1000
};

// Not supported here yet: Shared, Mipmaps, UnorderedAccess, and multisampling (sampleCount > 1
// renders single-sampled, so ResolveTo has nothing to do).
Texture* GLRenderDevice::CreateRenderTarget(int width, int height, int flags, int sampleCount)
{
#ifdef BF_PLATFORM_OPENGL_ES2
	NOT_IMPL;
#else
	if ((width <= 0) || (height <= 0))
		return NULL;

	GLint internalFormat = GL_RGBA8;
	GLenum format = GL_RGBA;
	GLenum type = GL_UNSIGNED_BYTE;
	if ((flags & GLRenderTargetFlag_HighPrecision) != 0)
	{
		internalFormat = GL_R32F; format = GL_RED; type = GL_FLOAT;
	}
	else if ((flags & GLRenderTargetFlag_R8) != 0)
	{
		internalFormat = GL_R8; format = GL_RED; type = GL_UNSIGNED_BYTE;
	}
	else if ((flags & GLRenderTargetFlag_F16) != 0)
	{
		internalFormat = GL_RGBA16F; format = GL_RGBA; type = GL_HALF_FLOAT;
	}
	else if ((flags & GLRenderTargetFlag_RG8) != 0)
	{
		internalFormat = GL_RG8; format = GL_RG; type = GL_UNSIGNED_BYTE;
	}
	else if ((flags & GLRenderTargetFlag_R16F) != 0)
	{
		internalFormat = GL_R16F; format = GL_RED; type = GL_HALF_FLOAT;
	}
	else if ((flags & GLRenderTargetFlag_R32Uint) != 0)
	{
		internalFormat = GL_R32UI; format = GL_RED_INTEGER; type = GL_UNSIGNED_INT;
	}
	else if ((flags & GLRenderTargetFlag_RG16F) != 0)
	{
		internalFormat = GL_RG16F; format = GL_RG; type = GL_HALF_FLOAT;
	}

	GLuint textureId = 0;
	bf_glGenTextures(1, &textureId);
	bf_glBindTexture(GL_TEXTURE_2D, textureId);
	bool integerFormat = ((flags & GLRenderTargetFlag_R32Uint) != 0);
	bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, integerFormat ? GL_NEAREST : GL_LINEAR);
	bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, integerFormat ? GL_NEAREST : GL_LINEAR);
	bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	bf_glTexImage2D(GL_TEXTURE_2D, 0, internalFormat, width, height, 0, format, type, NULL);

	GLTexture* glTexture = new GLTexture();
	glTexture->mRenderDevice = this;
	glTexture->mGLTexture = textureId;
	glTexture->mGLTexture2 = 0;
	glTexture->mIsRenderTarget = true;
	glTexture->mWidth = width;
	glTexture->mHeight = height;

	if ((flags & (GLRenderTargetFlag_Depth | GLRenderTargetFlag_Stencil)) != 0)
	{
		bool wantStencil = (flags & GLRenderTargetFlag_Stencil) != 0;
		glTexture->mGLDepthHasStencil = wantStencil;
		bf_glGenRenderbuffers(1, &glTexture->mGLDepthBuffer);
		bf_glBindRenderbuffer(GL_RENDERBUFFER, glTexture->mGLDepthBuffer);
		bf_glRenderbufferStorage(GL_RENDERBUFFER, wantStencil ? GL_DEPTH24_STENCIL8 : GL_DEPTH_COMPONENT24, width, height);
		bf_glBindRenderbuffer(GL_RENDERBUFFER, 0);
	}

	glTexture->AddRef();
	return glTexture;
#endif
}

Texture* GLRenderDevice::CreateDynTexture(int width, int height)
{
	auto context = bf_SDL_GL_GetCurrentContext();
	auto err = bf_SDL_GetError();
	GLuint texture = 0;
	bf_glGenTextures(1, &texture);
	auto result = bf_glGetError();

	bf_glBindTexture(GL_TEXTURE_2D, texture);
	bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	bf_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);

	GLTexture* glTexture = new GLTexture();
	glTexture->mGLTexture = texture;
	glTexture->mGLTexture2 = 0;
	glTexture->mRenderDevice = this;
	glTexture->mWidth = width;
	glTexture->mHeight = height;
	glTexture->AddRef();
	return glTexture;
}

void GLRenderDevice::SetRenderState(RenderState* renderState)
{
	mCurRenderState = renderState;
}

void GLSetTextureCmd::Render(RenderDevice* renderDevice, RenderWindow* renderWindow)
{
/*#ifdef BF_PLATFORM_OPENGL_ES2
	//bf_glClientActiveTexture(GL_TEXTURE0);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, ((GLTexture*)mTexture)->mGLTexture);
	glUniform1i(curShader->mAttribTex0, 0);

	//bf_glClientActiveTexture(GL_TEXTURE1);

	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, ((GLTexture*)mTexture)->mGLTexture2);
	glUniform1i(curShader->mAttribTex1, 1);

	//glEnable(GL_TEXTURE_2D);
#else
	glActiveTexture(GL_TEXTURE0 + mTextureIdx);
	glBindTexture(GL_TEXTURE_2D, ((GLTexture*)mTexture)->mGLTexture);
#endif*/

	auto glTexture = (GLTexture*)mTexture;
	auto glRenderDevice = (GLRenderDevice*)renderDevice;

	if (glRenderDevice->mBlankTexture == 0)
	{
		bf_glGenTextures(1, &glRenderDevice->mBlankTexture);
		bf_glBindTexture(GL_TEXTURE_2D, glRenderDevice->mBlankTexture);
		bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

		/*if (bf_glCompressedTexImage2D != NULL)
		{
			uint64 hwData = 0;
			bf_glCompressedTexImage2D(GL_TEXTURE_2D, 0, GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG, 4, 4, 0,
									  sizeof(hwData), (uint8*)&hwData);
		}
		else*/
		{
			uint16 color = 0;
			bf_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0,
				GL_RGBA, GL_UNSIGNED_SHORT_4_4_4_4, &color);
		}
		bf_glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	}

	if (glTexture->mImageData != NULL)
	{
		glTexture->mGLTexture2 = glRenderDevice->mBlankTexture;

		int texCount = 1;
		//texCount = (imageData->mHWBitsType == HWBITS_PVRTC_2X4BPPV1) ? 2 : 1;

		for (int texNum = 0; texNum < 2/*texCount*/; texNum++)
		{
			GLuint glTextureID;
			bf_glGenTextures(1, &glTextureID);
			bf_glBindTexture(GL_TEXTURE_2D, glTextureID);
			bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
			bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
			bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
			bf_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

			//if (imageData->mHWBits != NULL)
			//{
			//	int internalFormat = (imageData->mHWBitsType == HWBITS_PVRTC_2BPPV1) ?
			//		GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG :
			//		GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG;

			//	int texSize = imageData->mHWBitsLength / texCount;

			//	bf_glCompressedTexImage2D(GL_TEXTURE_2D, 0, internalFormat, imageData->mWidth, imageData->mHeight, 0,
			//		texSize, (uint8*)imageData->mHWBits /*+ (texNum * texSize)*/);
			//}
			//else
			{
				bf_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, glTexture->mImageData->mWidth, glTexture->mImageData->mHeight, 0,
					GL_RGBA, GL_UNSIGNED_BYTE, glTexture->mImageData->mBits);
			}

			bf_glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

			if (texNum == 0)
				glTexture->mGLTexture = glTextureID;
			else
				glTexture->mGLTexture2 = glTextureID;
		}

		glTexture->mImageData->Deref();
		glTexture->mImageData = NULL;
	}

	bf_glActiveTexture(GL_TEXTURE0 + mTextureIdx);
	//glUniform1i(curShader->mAttribTex0, 0);
	bf_glBindTexture(GL_TEXTURE_2D, glTexture->mGLTexture);
}

/// Capture the window's client area as top-down RGBA.
///
/// Defined here rather than in SdlBFApp.cpp with the rest of SdlBFWindow because the GL
/// entry points are loaded at runtime into file-local pointers in this translation unit.
/// The Windows override blits from the window DC; there is no equivalent on this path, so
/// the framebuffer is read back directly.
bool SdlBFWindow::CaptureClientBits(uint32* outBits, int width, int height)
{
	if (mSDLWindow == NULL)
		return false;
	if ((outBits == NULL) || (width <= 0) || (height <= 0))
		return false;

	int clientWidth = 0;
	int clientHeight = 0;
	if (!bf_SDL_GetWindowSizeInPixels(mSDLWindow, &clientWidth, &clientHeight))
		return false;
	if ((width != clientWidth) || (height != clientHeight))
		return false;

	SdlBFApp* app = (SdlBFApp*)gBFApp;
	GLRenderWindow* glRenderWindow = (GLRenderWindow*)mRenderWindow;
	if ((app == NULL) || (glRenderWindow == NULL) || (glRenderWindow->mGLContext == NULL))
		return false;
	if (!bf_SDL_GL_MakeCurrent(mSDLWindow, glRenderWindow->mGLContext))
		return false;
	if (bf_glReadPixels == NULL)
		return false;

	int64 rowBytes = (int64)width * 4;
	uint8* readBuffer = new uint8[rowBytes * height];

	bf_glPixelStorei(GL_PACK_ALIGNMENT, 1);
	bf_glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, readBuffer);

	if (bf_glGetError() != GL_NO_ERROR)
	{
		delete [] readBuffer;
		return false;
	}

	// glReadPixels reports the framebuffer bottom-up where the Windows path produces
	// top-down, so the rows are reversed on the way out. The channel order is already
	// RGBA, which is what the other capture paths in this codebase produce.
	uint8* dst = (uint8*)outBits;
	for (int y = 0; y < height; y++)
		memcpy(dst + (rowBytes * y), readBuffer + (rowBytes * (height - 1 - y)), rowBytes);

	// A context created without an alpha channel reads back alpha as 0 rather than as
	// opaque. UICapture ors in a full alpha itself, so this is not what keeps a capture
	// from coming out transparent, but it leaves the buffer correct for a direct caller
	// and costs one pass over pixels already in cache.
	int64 pixelCount = (int64)width * height;
	for (int64 i = 0; i < pixelCount; i++)
		dst[i * 4 + 3] = 0xFF;

	delete [] readBuffer;
	return true;
}
