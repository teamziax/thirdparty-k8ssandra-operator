package cassandra

import (
	"testing"

	api "github.com/k8ssandra/k8ssandra-operator/apis/k8ssandra/v1alpha1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const twoNetworks = `[
  {"name": "ovn-kubernetes", "interface": "eth0", "ips": ["10.128.2.5"], "default": true},
  {"name": "cassandra/public", "interface": "net1", "ips": ["2001:db8:a000::7", "203.0.113.7"]}
]`

func testPod(annotations map[string]string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: "cassandra", Name: "dc1-r1-sts-0", Annotations: annotations},
		Status:     corev1.PodStatus{PodIP: "10.128.2.5"},
	}
}

func TestAdvertisedAddress(t *testing.T) {
	tests := []struct {
		name        string
		annotations map[string]string
		want        string
		wantErr     bool
	}{
		{name: "no advertised network: the pod IP", want: "10.128.2.5"},
		{
			name:        "advertised network by its full name",
			annotations: map[string]string{api.AdvertisedNetworkAnnotation: "cassandra/public", networkStatusAnnotation: twoNetworks},
			want:        "2001:db8:a000::7",
		},
		{
			name:        "advertised network by name alone, in the pod's namespace",
			annotations: map[string]string{api.AdvertisedNetworkAnnotation: "public", networkStatusAnnotation: twoNetworks},
			want:        "2001:db8:a000::7",
		},
		{
			name:        "advertised network not attached",
			annotations: map[string]string{api.AdvertisedNetworkAnnotation: "cassandra/other", networkStatusAnnotation: twoNetworks},
			wantErr:     true,
		},
		{
			name:        "network attached without an address yet",
			annotations: map[string]string{api.AdvertisedNetworkAnnotation: "cassandra/public", networkStatusAnnotation: `[{"name": "cassandra/public", "ips": []}]`},
			wantErr:     true,
		},
		{
			name:        "no network status yet",
			annotations: map[string]string{api.AdvertisedNetworkAnnotation: "cassandra/public"},
			wantErr:     true,
		},
		{
			name:        "unreadable network status",
			annotations: map[string]string{api.AdvertisedNetworkAnnotation: "cassandra/public", networkStatusAnnotation: "{"},
			wantErr:     true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := AdvertisedAddress(testPod(tt.annotations))
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}
