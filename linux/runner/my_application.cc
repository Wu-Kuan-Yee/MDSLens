#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <pango/pangocairo.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

// Flutter engine creation and plugin registration can take a noticeable
// amount of time on Linux, especially on a cold start.  Keep the native
// window responsive while that work is deferred to the next main-loop turn.
struct FlutterViewBootstrap {
  MyApplication* application;
  GtkWindow* window;
  GtkWidget* splash;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gint compare_font_family_names(gconstpointer left,
                                      gconstpointer right) {
  const gchar* left_name = *static_cast<gchar* const*>(left);
  const gchar* right_name = *static_cast<gchar* const*>(right);
  return g_ascii_strcasecmp(left_name, right_name);
}

static void system_fonts_method_call_cb(
    FlMethodChannel* channel,
    FlMethodCall* method_call,
    gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "listFamilies") != 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  PangoFontMap* font_map = pango_cairo_font_map_get_default();
  PangoFontFamily** families = nullptr;
  int family_count = 0;
  pango_font_map_list_families(font_map, &families, &family_count);

  g_autoptr(FlValue) result = fl_value_new_list();
  GPtrArray* names = g_ptr_array_new_with_free_func(g_free);
  for (int index = 0; index < family_count; ++index) {
    const gchar* name = pango_font_family_get_name(families[index]);
    if (name != nullptr && *name != '\0') {
      g_ptr_array_add(names, g_strdup(name));
    }
  }
  g_free(families);
  g_ptr_array_sort(names, compare_font_family_names);
  for (guint index = 0; index < names->len; ++index) {
    fl_value_append_take(
        result,
        fl_value_new_string(static_cast<const gchar*>(
            g_ptr_array_index(names, index))));
  }
  g_ptr_array_unref(names);

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(method_call, response, nullptr);
}

static void set_window_icon(GtkWindow* window) {
  // Desktop packages expose the icon by application ID. The bundled PNG is a
  // fallback for portable archives and desktop environments that do not use
  // the installed .desktop metadata.
  gtk_window_set_icon_name(window, APPLICATION_ID);

  g_autoptr(GError) error = nullptr;
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", &error);
  if (executable == nullptr) {
    return;
  }
  g_autofree gchar* bundle_dir = g_path_get_dirname(executable);
  g_autofree gchar* icon_path =
      g_build_filename(bundle_dir, "data", "app_icon.png", nullptr);
  if (g_file_test(icon_path, G_FILE_TEST_IS_REGULAR)) {
    gtk_window_set_icon_from_file(window, icon_path, nullptr);
  }
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static GtkWidget* create_startup_splash() {
  GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
  gtk_widget_set_valign(box, GTK_ALIGN_CENTER);

  GtkWidget* title = gtk_label_new("MDSLens");
  gtk_widget_set_name(title, "mdslens-startup-title");
  gtk_widget_set_halign(title, GTK_ALIGN_CENTER);
  gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);

  GtkWidget* spinner = gtk_spinner_new();
  gtk_spinner_start(GTK_SPINNER(spinner));
  gtk_widget_set_halign(spinner, GTK_ALIGN_CENTER);
  gtk_box_pack_start(GTK_BOX(box), spinner, FALSE, FALSE, 0);

  GtkWidget* detail = gtk_label_new("Starting...");
  gtk_widget_set_halign(detail, GTK_ALIGN_CENTER);
  gtk_box_pack_start(GTK_BOX(box), detail, FALSE, FALSE, 0);
  return box;
}

static void destroy_flutter_view_bootstrap(gpointer data) {
  auto* bootstrap = static_cast<FlutterViewBootstrap*>(data);
  if (bootstrap->window != nullptr) {
    g_object_unref(bootstrap->window);
  }
  g_free(bootstrap);
}

static gboolean initialize_flutter_view(gpointer data) {
  auto* bootstrap = static_cast<FlutterViewBootstrap*>(data);
  GtkWindow* window = bootstrap->window;
  if (!gtk_widget_get_visible(GTK_WIDGET(window))) {
    return G_SOURCE_REMOVE;
  }

  if (bootstrap->splash != nullptr) {
    gtk_widget_destroy(bootstrap->splash);
    bootstrap->splash = nullptr;
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, bootstrap->application->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) system_fonts_channel =
      fl_method_channel_new(messenger, "mdslens/system_fonts",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      system_fonts_channel, system_fonts_method_call_cb, bootstrap->application,
      nullptr);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the native window immediately; the Flutter surface takes over after
  // its first frame without delaying the user's first visual response.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           bootstrap->application);
  gtk_widget_realize(GTK_WIDGET(view));
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  gtk_widget_grab_focus(GTK_WIDGET(view));
  return G_SOURCE_REMOVE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "MDSLens");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "MDSLens");
  }

  set_window_icon(window);
  gtk_window_set_default_size(window, 1440, 920);
  GtkWidget* splash = create_startup_splash();
  gtk_container_add(GTK_CONTAINER(window), splash);
  gtk_widget_show_all(GTK_WIDGET(window));

  auto* bootstrap = g_new0(FlutterViewBootstrap, 1);
  bootstrap->application = self;
  bootstrap->window = GTK_WINDOW(g_object_ref(window));
  bootstrap->splash = splash;
  g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, initialize_flutter_view, bootstrap,
                  destroy_flutter_view_bootstrap);
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
