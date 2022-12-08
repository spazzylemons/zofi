package mode

import (
	"fmt"
	"os"
	"os/exec"
	"sort"

	"code.rocketnine.space/tslocum/desktop"
)

type DesktopMode struct {
	choices  []string
	commands map[string]*desktop.Entry
}

func NewDesktopMode() DesktopMode {
	result := DesktopMode{}
	result.commands = searchDirs()
	result.choices = make([]string, len(result.commands))
	index := 0
	for name := range result.commands {
		result.choices[index] = name
		index++
	}

	sort.Strings(result.choices)
	return result
}

func searchDirs() map[string]*desktop.Entry {
	cmds := map[string]*desktop.Entry{}
	entries, err := desktop.Scan(desktop.DataDirs())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return cmds
	}

	for _, entryList := range entries {
		for _, entry := range entryList {
			if entry.Type == desktop.Application {
				// TODO locale functionality
				if _, found := cmds[entry.Name]; !found {
					cmds[entry.Name] = entry
				}
			}
		}
	}

	return cmds
}

func (d *DesktopMode) Choices() []string {
	return d.choices
}

func (d *DesktopMode) CustomAllowed() bool {
	return false
}

func (d *DesktopMode) Execute(choice string) {
	entry := d.commands[choice]
	if entry != nil {
		err := exec.Command("sh", "-c", entry.Exec).Start()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
		}
	}
}
