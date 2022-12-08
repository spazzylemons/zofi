package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/gotk3/gotk3/gtk"
	"github.com/spazzylemons/zofi/launcher"
	"github.com/spazzylemons/zofi/mode"
)

func printUsage() {
	fmt.Println("usage: zofi [-h] [-v] [-m mode] [-sx width] [-sy height]")
	fmt.Println("general options:")
	fmt.Println("  -h          display this help and exit")
	fmt.Println("  -v          display program information and exit")
	fmt.Println("  -m mode     change the operating mode (default: command)")
	fmt.Println("modes:")
	fmt.Println("  command     run commands directly")
	fmt.Println("  desktop     run desktop applications")
	fmt.Println("configuration:")
	fmt.Println("  -sx width   set the width of the window (default: 640)")
	fmt.Println("  -sy height  set the height of the window (default: 320)")
}

func main() {
	launcher := launcher.Launcher{}

	var modeName string
	set := flag.NewFlagSet("zofi", flag.ContinueOnError)
	set.IntVar(&launcher.Width, "sx", 640, "set the width of the window")
	set.IntVar(&launcher.Height, "sy", 320, "set the height of the window")
	set.StringVar(&modeName, "m", "command", "change the operating mode")
	set.Usage = printUsage

	err := set.Parse(os.Args[1:])
	if err != nil {
		if err != flag.ErrHelp {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	if modeName == "command" {
		m := mode.NewCommandMode()
		launcher.Mode = &m
	} else if modeName == "desktop" {
		m := mode.NewDesktopMode()
		launcher.Mode = &m
	} else {
		fmt.Fprintf(os.Stderr, "unknown mode %v\n", modeName)
	}

	gtk.Init(nil)

	err = launcher.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
}
