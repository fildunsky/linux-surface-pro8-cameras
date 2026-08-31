/* v4l2-relayd - V4L2 camera streaming relay daemon
 * Copyright (C) 2020 Canonical Ltd.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; version 2 of the License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details:
 */

#if defined (HAVE_CONFIG_H)
#include "config.h"
#endif

#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

#include <glib.h>
#include <glib-unix.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video-info.h>

// See https://github.com/umlaeute/v4l2loopback/blob/9ba7e294ea6f45410a15f192381d4918e8df4f02/v4l2loopback.c#L800
// for the value.
#define V4L2LOOPBACK_EVENT_BASE (V4L2_EVENT_PRIVATE_START)
#define V4L2LOOPBACK_EVENT_OFFSET 0x08E00000
#define V4L2_EVENT_PRI_CLIENT_USAGE \
  (V4L2LOOPBACK_EVENT_BASE + V4L2LOOPBACK_EVENT_OFFSET + 1)


struct v4l2_event_client_usage {
  __u32 count;
};

GST_DEBUG_CATEGORY_STATIC (gst_debug_category);
#define GST_CAT_DEFAULT gst_debug_category

static gboolean opt_background = FALSE;
static gboolean opt_debug = FALSE;
static gboolean opt_version = FALSE;
static gchar *opt_input = NULL;
static gchar *opt_output = NULL;
static gchar *opt_splash =
    "dataurisrc uri=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAEElEQVQoz2NgGAWjYBTAAAADEAABaJFtwwAAAABJRU5ErkJggg== ! pngdec ! imagefreeze num-buffers=2 ! videoscale ! videoconvert"; /* 16x16 black PNG */

static GMainLoop *loop = NULL;
static guint input_bus_watch_id = 0;
static guint output_bus_watch_id = 0;
static guint splash_bus_watch_id = 0;
static guint v4l2_event_poll_id = 0;
static GstElement *input_pipeline = NULL;
static GstElement *output_pipeline = NULL;
static GstElement *splash_pipeline = NULL;

static gboolean    backend_pipeline_bus_call (GstBus      *bus,
                                              GstMessage  *msg,
                                              gpointer     data);
static GstElement* backend_pipeline_create   (const gchar *name,
                                              const gchar *description,
                                              guint       *bus_watch_id);

static const GOptionEntry opt_entries[] =
{
  { "background", 'D', G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE,
    &opt_background, "Run in the background", NULL },
  { "debug",      'd', G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE,
    &opt_debug, "Print debugging information", NULL },
  { "version",    'v', G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE,
    &opt_version, "Show version", NULL },
  { "input",      'i', G_OPTION_FLAG_NONE, G_OPTION_ARG_STRING,
    &opt_input, "Specify input GStreamer pipeline description", NULL},
  { "output",     'o', G_OPTION_FLAG_NONE, G_OPTION_ARG_FILENAME,
    &opt_output, "Specify output GStreamer pipeline description", NULL},
  { "splash",     's', G_OPTION_FLAG_NONE, G_OPTION_ARG_FILENAME,
    &opt_splash, "Specify splash GStreamer pipeline description", NULL},
  { NULL }
};

static void
parse_args (int   argc,
            char *argv[])
{
  GError *error = NULL;
  GOptionContext *context;

  context = g_option_context_new ("- test tree model performance");
  g_option_context_add_main_entries (context, opt_entries, NULL);
  g_option_context_set_help_enabled (context, TRUE);

  g_option_context_add_group (context, gst_init_get_option_group ());

  if (!g_option_context_parse (context, &argc, &argv, &error))
  {
    if (error != NULL) {
      g_printerr ("option parsing failed: %s\n", error->message);
      g_error_free (error);
    } else
      g_printerr ("option parsing failed: unknown error\n");

    g_option_context_free (context);
    exit (1);
  }

  g_option_context_free (context);

  if (opt_version) {
    g_print ("%s (%s)\n", g_get_prgname (), V4L2_RELAYD_VERSION);
    exit (0);
  }

  if (opt_debug) {
    g_log_set_handler (G_LOG_DOMAIN, G_LOG_LEVEL_INFO,
                       g_log_default_handler, NULL);
    g_log_set_handler (G_LOG_DOMAIN, G_LOG_LEVEL_DEBUG,
                       g_log_default_handler, NULL);
  }

  if (opt_background) {
    if (daemon (0, 0) < 0) {
      int saved_errno;

      saved_errno = errno;
      g_printerr ("Could not daemonize: %s [error %u]\n",
                  g_strerror (saved_errno), saved_errno);
      exit (1);
    }
  }
}

static gboolean
backend_pipeline_bus_call (GstBus     *bus,
                           GstMessage *msg,
                           gpointer    data)
{
  GstElement *pipeline = GST_ELEMENT (data);

  switch (GST_MESSAGE_TYPE (msg)) {
    case GST_MESSAGE_ERROR: {
      gchar  *debug;
      GError *error;

      gst_message_parse_error (msg, &error, &debug);
      g_free (debug);

      GST_ERROR ("%s", error->message);
      g_error_free (error);

      gst_element_set_state (pipeline, GST_STATE_NULL);
      break;
    }
    default:
      break;
  }

  return TRUE;
}

static GstFlowReturn
backend_appsink_new_sample (GstAppSink *appsink,
                            gpointer    user_data)
{
  GstAppSrc *appsrc = (GstAppSrc *) user_data;
  GstSample *sample;
  GstBuffer *buffer;

  sample = gst_app_sink_pull_sample (appsink);
  buffer = gst_sample_get_buffer (sample);
  /* gst_app_src_push_buffer wants to take the ownership of the buffer,
   * so it must hold an additional reference first. */
  gst_buffer_ref (buffer);
  gst_app_src_push_buffer (appsrc, buffer);
  gst_sample_unref (sample);

  return GST_FLOW_OK;
}

static GstElement*
backend_pipeline_create (const gchar *name,
                         const gchar *description,
                         guint       *bus_watch_id)
{
  GstElement *appsrc, *pipeline, *appsink, *element;
  GstPad *src_pad;
  GstClock *clock;
  GError *error = NULL;
  GstCaps *caps;
  GstBus *bus;

  element = gst_parse_launch_full (description, NULL,
                                   GST_PARSE_FLAG_FATAL_ERRORS, &error);
  if (element == NULL) {
    GST_ERROR ("%s", error->message);
    g_error_free (error);
    return NULL;
  }
  if (!GST_IS_PIPELINE (element)) {
    pipeline = gst_pipeline_new (NULL);
    gst_bin_add (GST_BIN (pipeline), element);
  } else
    pipeline = element;
  gst_object_ref_sink (pipeline);
  gst_element_set_name (pipeline, name);

  src_pad = gst_bin_find_unlinked_pad (GST_BIN (pipeline), GST_PAD_SRC);
  if (src_pad == NULL) {
    GST_ERROR ("no src pad available in %s", name);
    gst_object_unref (pipeline);
    return NULL;
  }

  clock = gst_system_clock_obtain ();
  gst_pipeline_use_clock (GST_PIPELINE (pipeline), clock);
  gst_element_set_base_time (pipeline,
                             gst_element_get_base_time (output_pipeline));
  gst_element_set_start_time (pipeline, GST_CLOCK_TIME_NONE);
  gst_object_unref (clock);

  appsrc = gst_bin_get_by_name (GST_BIN (output_pipeline), "appsrc");
  caps = gst_app_src_get_caps (GST_APP_SRC (appsrc));

  appsink = gst_element_factory_make ("appsink", NULL);
  g_object_set (appsink,
                "caps", caps,
                "drop", TRUE,
                "max-buffers", 4,
                "emit-signals", TRUE,
                NULL);
  g_signal_connect_object (appsink,
                           "new-sample", (GCallback) backend_appsink_new_sample,
                           appsrc, 0);
  gst_caps_unref (caps);

  gst_bin_add (GST_BIN (pipeline), appsink);
  element = gst_pad_get_parent_element (src_pad);
  gst_element_link (element, appsink);
  gst_object_unref (element);
  gst_object_unref (src_pad);

  bus = gst_pipeline_get_bus (GST_PIPELINE (pipeline));
  *bus_watch_id = gst_bus_add_watch_full (bus, G_PRIORITY_DEFAULT,
                                          backend_pipeline_bus_call,
                                          gst_object_ref (pipeline),
                                          gst_object_unref);
  gst_object_unref (bus);

  return pipeline;
}

static GstElement*
input_pipeline_get ()
{
  if (input_pipeline == NULL) {
    input_pipeline = backend_pipeline_create ("input-pipeline", opt_input,
                                              &input_bus_watch_id);
  }
  return input_pipeline;
}

static GstElement*
splash_pipeline_get ()
{
  if (splash_pipeline == NULL) {
    splash_pipeline = backend_pipeline_create ("splash-pipeline", opt_splash,
                                               &splash_bus_watch_id);
  }
  return splash_pipeline;
}

/*
 * Выровнять базу времени подчинённого конвейера с выходным.
 *
 * backend_pipeline_create() делает это один раз при создании и ставит
 * start_time в GST_CLOCK_TIME_NONE, чтобы база пережила смену состояний.
 * Но входной конвейер и заставка многократно переводятся в GST_STATE_NULL и
 * обратно, и база при этом теряется. Дальше живой источник считает метки
 * времени от новой базы, то есть заново от нуля, а выходной конвейер живёт со
 * своей исходной. Расхождение равно времени работы демона и растёт без
 * предела: приёмник считает все кадры камеры опоздавшими и выбрасывает их,
 * потребитель получает одну заставку.
 *
 * Замерено на Surface Pro 8 (libcamerasrc, IPU6): сразу после запуска службы
 * приходит 173 живых кадра за 6 секунд, через 25 минут работы — ноль живых и
 * 784 кадра заставки в секунду.
 *
 * Поэтому выравниваем базу перед каждым включением, а не только при создании.
 */
static void
backend_pipeline_sync_base_time (GstElement *pipeline)
{
  if (pipeline == NULL || output_pipeline == NULL)
    return;

  gst_element_set_base_time (pipeline,
                             gst_element_get_base_time (output_pipeline));
  gst_element_set_start_time (pipeline, GST_CLOCK_TIME_NONE);
}

static void
input_pipeline_enable ()
{
  gst_element_set_state (splash_pipeline_get (), GST_STATE_NULL);
  backend_pipeline_sync_base_time (input_pipeline_get ());
  gst_element_set_state (input_pipeline_get (), GST_STATE_PLAYING);
}

static void
input_pipeline_disable ()
{
  if (input_pipeline != NULL)
    gst_element_set_state (input_pipeline, GST_STATE_NULL);
  if (input_pipeline != NULL) {
    backend_pipeline_sync_base_time (splash_pipeline);
    gst_element_set_state (splash_pipeline, GST_STATE_PLAYING);
  }
}

static gboolean
v4l2sink_event_callback (gint         fd,
                         GIOCondition condition,
                         gpointer     user_data G_GNUC_UNUSED)
{
  struct v4l2_event event;
  int ret;

  if (!(condition & G_IO_PRI))
    return TRUE;

  do {
    memset (&event, 0, sizeof (event));

    ret = ioctl (fd, VIDIOC_DQEVENT, &event);
    if (ret < 0)
      return TRUE;

    GST_TRACE ("Received V4L2 event type %u", event.type);
    switch (event.type) {
      case V4L2_EVENT_PRI_CLIENT_USAGE: {
        struct v4l2_event_client_usage usage;

        memcpy (&usage, &event.u, sizeof usage);
        GST_DEBUG ("Current V4L2 client: %u", usage.count);
        if (usage.count)
          input_pipeline_enable ();
        else
          input_pipeline_disable ();

        break;
      }
      default:
        break;
    }
  } while (event.pending);

  return TRUE;
}

static gboolean
output_pipeline_bus_call (GstBus     *bus,
                          GstMessage *msg,
                          gpointer    data G_GNUC_UNUSED)
{
  switch (GST_MESSAGE_TYPE (msg)) {
    case GST_MESSAGE_STATE_CHANGED: {
      GstState old_state, new_state;
      GstElement *v4l2sink;
      int fd = -1;
      struct v4l2_event_subscription sub;

      if (!GST_IS_PIPELINE (GST_MESSAGE_SRC (msg)))
        break;

      g_assert (GST_ELEMENT (GST_MESSAGE_SRC (msg)) == output_pipeline);

      gst_message_parse_state_changed (msg, &old_state, &new_state, NULL);
      GST_DEBUG ("Output pipeline state changed from %s to %s",
                 gst_element_state_get_name (old_state),
                 gst_element_state_get_name (new_state));

      if (old_state == GST_STATE_PLAYING) {
        if (v4l2_event_poll_id > 0) {
          g_source_remove (v4l2_event_poll_id);
          v4l2_event_poll_id = 0;
        }
        break;
      }

      if (old_state == GST_STATE_READY && new_state == GST_STATE_PAUSED) {
        backend_pipeline_sync_base_time (splash_pipeline_get ());
        gst_element_set_state (splash_pipeline_get (), GST_STATE_PLAYING);
      }

      if (new_state != GST_STATE_PLAYING)
        break;

      v4l2sink = gst_bin_get_by_name (GST_BIN (output_pipeline), "v4l2sink");
      if (v4l2sink == NULL)
        break;

      g_object_get (v4l2sink, "device-fd", &fd, NULL);

      memset (&sub, 0, sizeof (sub));
      sub.type = V4L2_EVENT_PRI_CLIENT_USAGE;
      sub.id = 0;
      sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
      if (ioctl (fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0)
        v4l2_event_poll_id =
            g_unix_fd_add (fd, G_IO_PRI, v4l2sink_event_callback, NULL);
      else
        GST_ERROR ("V4L2_EVENT_PRI_CLIENT_USAGE not supported");

      gst_object_unref (v4l2sink);
      break;
    }
    case GST_MESSAGE_EOS:
      g_main_loop_quit (loop);
      break;

    case GST_MESSAGE_ERROR: {
      gchar  *debug;
      GError *error;

      gst_message_parse_error (msg, &error, &debug);
      g_free (debug);

      GST_ERROR ("%s", error->message);
      g_error_free (error);

      g_main_loop_quit (loop);
      break;
    }
    default:
      break;
  }

  return TRUE;
}

static GstElement*
output_pipeline_create ()
{
  GstElement *pipeline, *appsrc;
  GstClock *clock;
  GError *error = NULL;
  GstBus *bus;

  pipeline = gst_parse_launch (opt_output, &error);
  if (pipeline == NULL) {
    GST_ERROR ("%s", error->message);
    g_error_free (error);
    return NULL;
  }
  gst_object_ref_sink (pipeline);

  clock = gst_system_clock_obtain ();
  gst_pipeline_use_clock (GST_PIPELINE (pipeline), clock);
  gst_element_set_base_time (pipeline, gst_clock_get_time (clock));
  gst_element_set_start_time (pipeline, GST_CLOCK_TIME_NONE);
  gst_object_unref (clock);

  appsrc = gst_bin_get_by_name (GST_BIN (pipeline), "appsrc");
  g_object_set (appsrc,
                "stream-type", GST_APP_STREAM_TYPE_STREAM,
                "format", GST_FORMAT_DEFAULT,
                "is-live", TRUE,
                "emit-signals", FALSE,
                NULL);
  gst_object_unref (appsrc);

  bus = gst_pipeline_get_bus (GST_PIPELINE (pipeline));
  output_bus_watch_id =
      gst_bus_add_watch (bus, output_pipeline_bus_call, NULL);
  gst_object_unref (bus);

  return pipeline;
}

int
main (int   argc,
      char *argv[])
{

  parse_args (argc, argv);

  GST_DEBUG_CATEGORY_INIT (GST_CAT_DEFAULT, "V4L2_RELAYD", 0, "v4l2-relayd");

  loop = g_main_loop_new (NULL, FALSE);
  output_pipeline = output_pipeline_create ();
  gst_element_set_state (output_pipeline, GST_STATE_PLAYING);

  GST_INFO ("Running...");
  g_main_loop_run (loop);

  g_source_remove (input_bus_watch_id);
  g_source_remove (output_bus_watch_id);
  g_source_remove (splash_bus_watch_id);

  gst_element_set_state (output_pipeline, GST_STATE_NULL);
  gst_object_unref (GST_OBJECT (output_pipeline));

  gst_element_set_state (input_pipeline, GST_STATE_NULL);
  gst_object_unref (GST_OBJECT (input_pipeline));

  gst_element_set_state (splash_pipeline, GST_STATE_NULL);
  gst_object_unref (GST_OBJECT (splash_pipeline));

  g_main_loop_unref (loop);

  return 0;
}
