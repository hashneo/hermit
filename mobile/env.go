//go:build !windows

package mobile

import "os"

func setEnv(key, value string) error {
	return os.Setenv(key, value)
}
