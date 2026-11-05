package cassandra

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"

	cassdcapi "github.com/k8ssandra/cass-operator/apis/cassandra/v1beta1"
	"github.com/k8ssandra/cass-operator/pkg/httphelper"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// apiServerProxyClient is an httphelper.HttpClient that sends Management API requests through the
// Kubernetes API server's pods/proxy subresource instead of connecting to pod IPs. It lets a control
// plane manage a datacenter in a cluster whose pod network it can't route to: the only connection it
// needs is to that cluster's API server, which it has anyway.
//
// The API server proxies to the pod over plain HTTP, or over HTTPS without presenting a client
// certificate, so a Management API that requires mutual TLS can't be reached this way.
type apiServerProxyClient struct {
	httpClient *http.Client
	server     *url.URL
	namespace  string
	// podName returns the name of the pod in namespace that has the IP the request was addressed to.
	podName func(ctx context.Context, podIP string) (string, error)
}

var _ httphelper.HttpClient = (*apiServerProxyClient)(nil)

// newApiServerProxyClient returns a client that reaches the Management API of dc's pods through the API
// server restConfig points at. k8sClient must be a client of that same cluster.
func newApiServerProxyClient(restConfig *rest.Config, dc *cassdcapi.CassandraDatacenter, k8sClient client.Client) (*apiServerProxyClient, error) {
	httpClient, err := rest.HTTPClientFor(restConfig)
	if err != nil {
		return nil, fmt.Errorf("building an HTTP client for the API server: %w", err)
	}
	server, err := apiServerURL(restConfig)
	if err != nil {
		return nil, err
	}
	return &apiServerProxyClient{
		httpClient: httpClient,
		server:     server,
		namespace:  dc.Namespace,
		podName:    datacenterPodNameByIP(k8sClient, dc),
	}, nil
}

// Do rewrites a request for http(s)://<pod IP>:<port><path> into one for the pod's proxy subresource,
// <API server>/api/v1/namespaces/<namespace>/pods/[https:]<pod name>:<port>/proxy<path>, and sends it with
// the API server's credentials.
func (c *apiServerProxyClient) Do(req *http.Request) (*http.Response, error) {
	host, port, err := net.SplitHostPort(req.URL.Host)
	if err != nil {
		return nil, fmt.Errorf("management API request for %q has no host and port: %w", req.URL.Host, err)
	}
	name, err := c.podName(req.Context(), host)
	if err != nil {
		return nil, err
	}
	proxied, err := proxyURL(c.server, c.namespace, name, req.URL.Scheme, port, req.URL)
	if err != nil {
		return nil, err
	}
	out := req.Clone(req.Context())
	out.URL = proxied
	out.Host = proxied.Host
	out.RequestURI = ""
	return c.httpClient.Do(out)
}

// proxyURL is the pods/proxy URL for target, a request to the pod's port over scheme.
func proxyURL(server *url.URL, namespace, podName, scheme, port string, target *url.URL) (*url.URL, error) {
	podRef := podName + ":" + port
	if scheme == "https" {
		podRef = "https:" + podRef
	}
	// Namespace and pod names are DNS labels, so the path needs no escaping of its own; URL.String escapes
	// target's path again as it encodes the whole.
	path := strings.TrimSuffix(server.Path, "/") + "/api/v1/namespaces/" + namespace + "/pods/" + podRef + "/proxy" +
		target.Path
	proxied := *server
	proxied.Path = path
	proxied.RawPath = ""
	proxied.RawQuery = target.RawQuery
	return &proxied, nil
}

// apiServerURL is the base URL of the API server restConfig points at.
func apiServerURL(restConfig *rest.Config) (*url.URL, error) {
	host := restConfig.Host
	if !strings.Contains(host, "://") {
		host = "https://" + host
	}
	server, err := url.Parse(host)
	if err != nil {
		return nil, fmt.Errorf("parsing the API server address %q: %w", restConfig.Host, err)
	}
	if restConfig.APIPath != "" && restConfig.APIPath != "/api" {
		return nil, fmt.Errorf("API server address %q has an unsupported API path %q", restConfig.Host, restConfig.APIPath)
	}
	return server, nil
}

// datacenterPodNameByIP looks pods up among dc's, by IP. It lists them by label, which the cached
// clients of remote clusters can serve, rather than with a status.podIP field selector, which they can't.
func datacenterPodNameByIP(k8sClient client.Client, dc *cassdcapi.CassandraDatacenter) func(context.Context, string) (string, error) {
	return func(ctx context.Context, podIP string) (string, error) {
		pods := &corev1.PodList{}
		if err := k8sClient.List(ctx, pods, client.InNamespace(dc.Namespace), client.MatchingLabels(dc.GetDatacenterLabels())); err != nil {
			return "", fmt.Errorf("listing the pods of datacenter %s: %w", dc.Name, err)
		}
		for _, pod := range pods.Items {
			for _, ip := range pod.Status.PodIPs {
				if ip.IP == podIP {
					return pod.Name, nil
				}
			}
			if pod.Status.PodIP == podIP {
				return pod.Name, nil
			}
		}
		return "", fmt.Errorf("no pod of datacenter %s has IP %s", dc.Name, podIP)
	}
}
