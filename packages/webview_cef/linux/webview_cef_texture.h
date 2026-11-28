#ifndef WEBVIEW_CEF_TEXTURE_H_
#define WEBVIEW_CEF_TEXTURE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>

// A pixel buffer texture fed from two threads.
//
// On Linux CEF runs its own message loop thread (multi_threaded_message_loop),
// so frames arrive on CEF's UI thread while Flutter reads them on its render
// thread. CEF writes into `buffer` under `mutex`; copy_pixels copies that,
// under the same lock, into `render_buffer`, which only the render thread
// touches and which stays valid after copy_pixels returns. The buffers are
// reallocated only when the size changes, and freed when the texture goes.
//
// GObject zero-fills instances and runs no C++ constructors, so the members
// are plain C: a GMutex, raw pointers, sizes.
struct WebviewCefTexture{
    FlPixelBufferTexture parent_instance;
    GMutex mutex;
    uint8_t *buffer;           // Written by CEF's thread, under mutex.
    size_t buffer_size;
    uint8_t *render_buffer;    // Handed to Flutter; render thread only.
    size_t render_buffer_size;
    uint32_t width;
    uint32_t height;
};

struct WebviewCefTextureClass{
    FlPixelBufferTextureClass parent_class;
};

G_DEFINE_TYPE(WebviewCefTexture,
              webview_cef_texture,
              fl_pixel_buffer_texture_get_type())

#define WEBVIEW_CEF_TEXTURE(obj) \
    (G_TYPE_CHECK_INSTANCE_CAST((obj), webview_cef_texture_get_type(), WebviewCefTexture))

// Grows or shrinks *buffer to exactly `size` bytes, keeping it when it already
// fits.
static void webview_cef_texture_resize(uint8_t **buffer, size_t *current,
                                       size_t size) {
    if (*buffer != nullptr && *current == size) {
        return;
    }
    delete[] *buffer;
    *buffer = size == 0 ? nullptr : new uint8_t[size];
    *current = size;
}

static gboolean webview_cef_texture_copy_pixels(FlPixelBufferTexture *texture,
                                                const uint8_t **out_buffer,
                                                uint32_t *width,
                                                uint32_t *height,
                                                GError **error) {
    // Called on Flutter's render thread.
    WebviewCefTexture *self = WEBVIEW_CEF_TEXTURE(texture);
    g_mutex_lock(&self->mutex);
    if (self->buffer == nullptr) {
        g_mutex_unlock(&self->mutex);
        // No frame from CEF yet. One transparent pixel rather than an error,
        // which Flutter logs as a warning on every frame until CEF paints.
        static const uint8_t kTransparentPixel[4] = {0, 0, 0, 0};
        *out_buffer = kTransparentPixel;
        *width = 1;
        *height = 1;
        return TRUE;
    }
    webview_cef_texture_resize(&self->render_buffer, &self->render_buffer_size,
                               self->buffer_size);
    memcpy(self->render_buffer, self->buffer, self->buffer_size);
    *width = self->width;
    *height = self->height;
    g_mutex_unlock(&self->mutex);
    *out_buffer = self->render_buffer;
    return TRUE;
}

// A frame from CEF, in BGRA; stored as the RGBA Flutter expects. Called on
// CEF's thread.
static void webview_cef_texture_set_frame(WebviewCefTexture *self,
                                          const void *bgra, int32_t width,
                                          int32_t height,
                                          void (*bgra_to_rgba)(void *,
                                                               const void *,
                                                               int, int)) {
    if (width <= 0 || height <= 0) {
        return;
    }
    const size_t size = static_cast<size_t>(width) * height * 4;
    g_mutex_lock(&self->mutex);
    webview_cef_texture_resize(&self->buffer, &self->buffer_size, size);
    bgra_to_rgba(self->buffer, bgra, width, height);
    self->width = static_cast<uint32_t>(width);
    self->height = static_cast<uint32_t>(height);
    g_mutex_unlock(&self->mutex);
}

static WebviewCefTexture* webview_cef_texture_new(){
    return WEBVIEW_CEF_TEXTURE(g_object_new(webview_cef_texture_get_type(), nullptr));
}

static void webview_cef_texture_finalize(GObject *object) {
    WebviewCefTexture *self = WEBVIEW_CEF_TEXTURE(object);
    delete[] self->buffer;
    delete[] self->render_buffer;
    self->buffer = nullptr;
    self->render_buffer = nullptr;
    g_mutex_clear(&self->mutex);
    G_OBJECT_CLASS(webview_cef_texture_parent_class)->finalize(object);
}

static void webview_cef_texture_class_init(WebviewCefTextureClass *klass)
{
    FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = webview_cef_texture_copy_pixels;
    G_OBJECT_CLASS(klass)->finalize = webview_cef_texture_finalize;
}

static void webview_cef_texture_init(WebviewCefTexture *self) {
    g_mutex_init(&self->mutex);
}


#endif // WEBVIEW_CEF_TEXTURE_H_
