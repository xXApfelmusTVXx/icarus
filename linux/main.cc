#include "my_application.h"

int main(int argc, char** argv) {
  // GTK names the X11 window class after the program, which is otherwise
  // whatever started it: in an AppImage, the AppImage's file name. Docks
  // match windows to the desktop entry by it.
  g_set_prgname(APPLICATION_ID);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
