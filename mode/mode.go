package mode

type Mode interface {
	// The choices the user can select from.
	// Must be lexicographically sorted.
	Choices() []string
	// If true, pressing enter without a selected choice is valid.
	CustomAllowed() bool
	// Execute the given choice.
	Execute(string)
}
