package launcher

// #cgo pkg-config: gtk-layer-shell-0
// #include <gtk-layer-shell.h>
//
// void setupLayerShell(void *obj) {
//     GtkWindow *window = GTK_WINDOW((GObject*) obj);
//     gtk_layer_init_for_window(window);
//     gtk_layer_set_layer(window, GTK_LAYER_SHELL_LAYER_TOP);
//     gtk_layer_set_keyboard_mode(window, GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);
// }
import "C"

import (
	"strings"
	"unsafe"

	"github.com/gotk3/gotk3/gdk"
	"github.com/gotk3/gotk3/glib"
	"github.com/gotk3/gotk3/gtk"
	"github.com/spazzylemons/zofi/mode"
)

type Launcher struct {
	Width     int
	Height    int
	Mode      mode.Mode
	command   *gtk.Entry
	view      *gtk.TreeView
	selection *gtk.TreeSelection
}

type choiceFilter struct {
	input   string
	choices []string
	store   *gtk.ListStore
}

func (f *choiceFilter) filterOnce(starting bool) {
	lowerInput := strings.ToLower(f.input)

	for _, choice := range f.choices {
		lowerChoice := strings.ToLower(choice)

		if starting {
			if !strings.HasPrefix(lowerChoice, lowerInput) {
				continue
			}
		} else {
			index := strings.Index(lowerChoice, lowerInput)
			if index == 0 || index == -1 {
				continue
			}
		}

		iter := f.store.Append()
		f.store.Set(iter, []int{0}, []any{choice})
	}
}

func (f *choiceFilter) filter() {
	f.filterOnce(true)
	f.filterOnce(false)
}

func (l *Launcher) rebuildList() {
	input, err := l.command.GetText()
	if err != nil {
		return
	}

	store, err := gtk.ListStoreNew(glib.TYPE_STRING)
	if err != nil {
		return
	}

	filter := choiceFilter{}
	filter.input = input
	filter.choices = l.Mode.Choices()
	filter.store = store
	filter.filter()

	l.view.SetModel(store)
	selection, err := l.view.GetSelection()
	if err != nil {
		return
	}
	l.selection = selection

	l.command.SetIconFromIconName(gtk.ENTRY_ICON_PRIMARY, "edit-find")
	if iter, found := store.GetIterFirst(); found {
		l.selection.SelectIter(iter)
	} else if l.Mode.CustomAllowed() {
		l.command.SetIconFromIconName(gtk.ENTRY_ICON_PRIMARY, "system-run")
	}
}

func (l *Launcher) useIter(model *gtk.TreeModel, iter *gtk.TreeIter) {
	l.selection.SelectIter(iter)
	path, err := model.GetPath(iter)
	if err != nil {
		return
	}
	l.view.ScrollToCell(path, nil, false, 0.0, 0.0)
}

func (l *Launcher) moveSelection(f func(*gtk.TreeModel, *gtk.TreeIter) bool) {
	if model, iter, found := l.selection.GetSelected(); found {
		m := model.ToTreeModel()
		if f(m, iter) {
			l.useIter(m, iter)
		}
	}
}

func (l *Launcher) onKeyPress(window *gtk.ApplicationWindow, event *gdk.Event) bool {
	ev := gdk.EventKeyNewFromEvent(event)
	if ev == nil {
		return false
	}

	key := ev.KeyVal()

	if key == gdk.KEY_Up {
		l.moveSelection(func(m *gtk.TreeModel, i *gtk.TreeIter) bool {
			return m.IterPrevious(i)
		})
		return true
	}

	if key == gdk.KEY_Down {
		l.moveSelection(func(m *gtk.TreeModel, i *gtk.TreeIter) bool {
			return m.IterNext(i)
		})
		return true
	}

	if key == gdk.KEY_Escape {
		window.Close()
		return true
	}

	if key == gdk.KEY_Return {
		if model, iter, found := l.selection.GetSelected(); found {
			m := model.ToTreeModel()
			value, err := m.GetValue(iter, 0)
			if err != nil {
				return true
			}
			str, err := value.GetString()
			if err != nil {
				return true
			}
			l.Mode.Execute(str)
			window.Close()
			return true
		}

		if l.Mode.CustomAllowed() {
			text, err := l.command.GetText()
			if err != nil {
				return true
			}
			l.Mode.Execute(text)
			window.Close()
			return true
		}

		return false
	}

	if key == gdk.KEY_Tab {
		if model, iter, found := l.selection.GetSelected(); found {
			m := model.ToTreeModel()
			value, err := m.GetValue(iter, 0)
			if err != nil {
				return true
			}
			str, err := value.GetString()
			if err != nil {
				return true
			}
			l.command.SetText(str)
			l.command.GrabFocusWithoutSelecting()
			l.command.SetPosition(-1)
		}

		return true
	}

	return false
}

func (l *Launcher) onActivate(app *gtk.Application) {
	window, err := gtk.ApplicationWindowNew(app)
	if err != nil {
		return
	}
	C.setupLayerShell(unsafe.Pointer(window.GObject))
	window.Connect("key-press-event", l.onKeyPress)
	window.SetDefaultSize(l.Width, l.Height)
	window.SetResizable(false)

	box, err := gtk.BoxNew(gtk.ORIENTATION_VERTICAL, 0)
	if err != nil {
		return
	}

	entry, err := gtk.EntryNew()
	if err != nil {
		return
	}

	l.command = entry
	box.Add(entry)
	l.command.Connect("changed", l.rebuildList)

	view, err := gtk.TreeViewNew()
	if err != nil {
		return
	}
	l.view = view

	renderer, err := gtk.CellRendererTextNew()
	if err != nil {
		return
	}

	column, err := gtk.TreeViewColumnNewWithAttribute("", renderer, "text", 0)
	if err != nil {
		return
	}

	view.InsertColumn(column, -1)
	view.SetHeadersVisible(false)

	scrolled_window, err := gtk.ScrolledWindowNew(nil, nil)
	if err != nil {
		return
	}

	scrolled_window.Add(view)
	box.PackEnd(scrolled_window, true, true, 0)

	l.rebuildList()

	window.Add(box)
	window.ShowAll()
}

func (l *Launcher) Run() error {
	app, err := gtk.ApplicationNew("spazzylemons.zofi", glib.APPLICATION_FLAGS_NONE)
	if err != nil {
		return err
	}

	app.Connect("activate", l.onActivate)
	app.Run(nil)

	return nil
}
