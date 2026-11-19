#include <gtk/gtk.h>

// Macros and variadic functions Swift can't import.
static inline const GVariantType *rf_variant_type_string(void) { return G_VARIANT_TYPE_STRING; }
static inline GType rf_type_file(void) { return G_TYPE_FILE; }
static inline GType rf_type_file_filter(void) { return GTK_TYPE_FILE_FILTER; }
static inline GtkAlertDialog *rf_alert_new(const char *message) { return gtk_alert_dialog_new("%s", message); }
