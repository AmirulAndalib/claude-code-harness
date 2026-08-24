package hostgen

import (
	"errors"
	"strings"
	"testing"
)

func hermesHost() Host {
	return Host{
		Name:              "hermes",
		HookEvent:         "pre_tool_call",
		DeliveryStrategy:  "turn",
		DeliveryEventTurn: "stop",
	}
}

func TestGenerateDeliveryHooksJSON_HermesTurnDelivery(t *testing.T) {
	out, ok, err := GenerateDeliveryHooksJSON(hermesHost())
	if err != nil {
		t.Fatalf("GenerateDeliveryHooksJSON(hermes): %v", err)
	}
	if !ok {
		t.Fatal("expected ok=true for hermes delivery config")
	}
	s := string(out)
	if !strings.Contains(s, `"stop"`) {
		t.Errorf("hermes delivery config missing stop event:\n%s", s)
	}
	if !strings.Contains(s, "inbox check --from-env") {
		t.Errorf("hermes delivery config missing inbox check command:\n%s", s)
	}
}

func TestGenerateHooksJSON_HermesDoesNotGenerateHookFile(t *testing.T) {
	_, err := GenerateHooksJSON(hermesHost())
	if !errors.Is(err, ErrHookGenerationDeferred) {
		t.Fatalf("GenerateHooksJSON(hermes) error = %v, want ErrHookGenerationDeferred", err)
	}
}
