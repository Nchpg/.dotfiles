package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

// Servi tout de suite tant que c'est récent ; un peu vieux : servi, et relu en arrière-plan ; trop
// vieux : attendu. Un résultat nil n'est pas gardé.
func TestSlowCache(t *testing.T) {
	var c slowCache
	var n atomic.Int32
	build := func(context.Context) any { return int(n.Add(1)) }
	if v := c.get("k", build); v != 1 {
		t.Fatalf("première lecture : %v", v)
	}
	if v := c.get("k", build); v != 1 || n.Load() != 1 {
		t.Fatalf("récent : %v (%d lectures)", v, n.Load())
	}
	c.m["k"].at = time.Now().Add(-2 * time.Minute)
	if v := c.get("k", build); v != 1 {
		t.Fatalf("un peu vieux, servi tel quel : %v", v)
	}
	for i := 0; i < 100 && c.get("k", build) != 2; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	if v := c.get("k", build); v != 2 {
		t.Fatalf("relu en arrière-plan : %v", v)
	}
	c.m["k"].at = time.Now().Add(-time.Hour)
	if v := c.get("k", build); v != 3 {
		t.Fatalf("trop vieux, attendu : %v", v)
	}
	if v := c.get("absent", func(context.Context) any { return nil }); v != nil || c.m["absent"] != nil {
		t.Fatalf("nil gardé : %v", v)
	}
}
