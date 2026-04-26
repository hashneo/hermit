package main

import (
	"flag"
	"fmt"
	"log"

	"hermit/internal/config"
)

func main() {
	checkAccess := flag.Bool("check-access", false, "no-op: token validation now happens at runtime via the /repositories/{id}/validate API")
	flag.Parse()

	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config validation failed: %v", err)
	}

	if *checkAccess {
		fmt.Println("note: --check-access is no longer supported; tokens are supplied at runtime via the native app or POST /api/v1/repositories")
	}

	fmt.Printf("config valid: environment=%s listen_address=%s registries=%d repositories=%d\n", cfg.Environment, cfg.ListenAddress, len(cfg.Registries), len(cfg.Repositories))
}
