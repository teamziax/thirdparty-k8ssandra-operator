package cassandra

import (
	"encoding/json"
	"fmt"

	api "github.com/k8ssandra/k8ssandra-operator/apis/k8ssandra/v1alpha1"
	corev1 "k8s.io/api/core/v1"
)

// networkStatusAnnotation is where Multus records the networks a pod is attached to, and their addresses.
const networkStatusAnnotation = "k8s.v1.cni.cncf.io/network-status"

// networkStatus is the part of a k8s.v1.cni.cncf.io/network-status entry this package reads.
type networkStatus struct {
	Name string   `json:"name"`
	IPs  []string `json:"ips"`
}

// AdvertisedAddress returns the address other datacenters should use to reach pod: its pod IP, unless it
// names a network in its AdvertisedNetworkAnnotation, in which case its first address on that network. It
// returns an error when the network is named but the pod has no address on it yet, rather than fall back
// to a pod IP that the other datacenters can't reach.
func AdvertisedAddress(pod *corev1.Pod) (string, error) {
	network := pod.Annotations[api.AdvertisedNetworkAnnotation]
	if network == "" {
		return pod.Status.PodIP, nil
	}
	raw, found := pod.Annotations[networkStatusAnnotation]
	if !found {
		return "", fmt.Errorf("pod %s/%s advertises network %q but has no %s annotation", pod.Namespace, pod.Name, network, networkStatusAnnotation)
	}
	var statuses []networkStatus
	if err := json.Unmarshal([]byte(raw), &statuses); err != nil {
		return "", fmt.Errorf("pod %s/%s has an unreadable %s annotation: %w", pod.Namespace, pod.Name, networkStatusAnnotation, err)
	}
	for _, status := range statuses {
		// Multus names a network in the pod's own namespace <namespace>/<name>; accept either form.
		if status.Name == network || status.Name == pod.Namespace+"/"+network {
			if len(status.IPs) == 0 {
				break
			}
			return status.IPs[0], nil
		}
	}
	return "", fmt.Errorf("pod %s/%s advertises network %q but has no address on it", pod.Namespace, pod.Name, network)
}
