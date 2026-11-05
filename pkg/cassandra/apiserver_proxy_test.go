package cassandra

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/client-go/rest"
)

func TestProxyURL(t *testing.T) {
	server, _ := url.Parse("https://api.example.com:6443")
	target, _ := url.Parse("http://10.128.2.5:8080/api/v0/ops/keyspace/replication?keyspace=system_auth")

	got, err := proxyURL(server, "cassandra", "dc1-r1-sts-0", "http", "8080", target)
	require.NoError(t, err)
	assert.Equal(t, "https://api.example.com:6443/api/v1/namespaces/cassandra/pods/dc1-r1-sts-0:8080/proxy/api/v0/ops/keyspace/replication?keyspace=system_auth", got.String())

	got, err = proxyURL(server, "cassandra", "dc1-r1-sts-0", "https", "8080", target)
	require.NoError(t, err)
	assert.Equal(t, "/api/v1/namespaces/cassandra/pods/https:dc1-r1-sts-0:8080/proxy/api/v0/ops/keyspace/replication", got.Path)

	prefixed, _ := url.Parse("https://proxy.example.com/clusters/dc1/")
	got, err = proxyURL(prefixed, "cassandra", "dc1-r1-sts-0", "http", "8080", target)
	require.NoError(t, err)
	assert.Equal(t, "/clusters/dc1/api/v1/namespaces/cassandra/pods/dc1-r1-sts-0:8080/proxy/api/v0/ops/keyspace/replication", got.Path)
}

func TestApiServerURL(t *testing.T) {
	got, err := apiServerURL(&rest.Config{Host: "api.example.com:6443"})
	require.NoError(t, err)
	assert.Equal(t, "https://api.example.com:6443", got.String())

	got, err = apiServerURL(&rest.Config{Host: "http://127.0.0.1:8001"})
	require.NoError(t, err)
	assert.Equal(t, "http://127.0.0.1:8001", got.String())

	_, err = apiServerURL(&rest.Config{Host: "https://api.example.com", APIPath: "/apis"})
	require.Error(t, err)
}

// The client sends a Management API request, method, body and headers included, to the pod's proxy
// subresource on the API server, and hands back the API server's response untouched.
func TestApiServerProxyClientDo(t *testing.T) {
	var gotMethod, gotPath, gotQuery, gotBody, gotContentType string
	apiServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotQuery = r.Method, r.URL.Path, r.URL.RawQuery
		gotContentType = r.Header.Get("Content-Type")
		body, _ := io.ReadAll(r.Body)
		gotBody = string(body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte("OK"))
	}))
	defer apiServer.Close()

	server, _ := url.Parse(apiServer.URL)
	client := &apiServerProxyClient{
		httpClient: apiServer.Client(),
		server:     server,
		namespace:  "cassandra",
		podName: func(_ context.Context, podIP string) (string, error) {
			if podIP == "fd01:0:0:3::12" {
				return "dc1-r1-sts-1", nil
			}
			return "", errors.New("unknown pod IP " + podIP)
		},
	}

	req, err := http.NewRequest(http.MethodPost, "http://[fd01:0:0:3::12]:8080/api/v0/ops/keyspace/create", strings.NewReader(`{"keyspace_name":"ks"}`))
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/json")
	res, err := client.Do(req)
	require.NoError(t, err)
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	assert.Equal(t, http.StatusCreated, res.StatusCode)
	assert.Equal(t, "OK", string(body))
	assert.Equal(t, http.MethodPost, gotMethod)
	assert.Equal(t, "/api/v1/namespaces/cassandra/pods/dc1-r1-sts-1:8080/proxy/api/v0/ops/keyspace/create", gotPath)
	assert.Empty(t, gotQuery)
	assert.Equal(t, `{"keyspace_name":"ks"}`, gotBody)
	assert.Equal(t, "application/json", gotContentType)

	// A pod the client can't resolve fails before anything reaches the API server.
	gotPath = ""
	req, _ = http.NewRequest(http.MethodGet, "http://10.128.9.9:8080/api/v0/probes/readiness", nil)
	_, err = client.Do(req)
	require.Error(t, err)
	assert.Empty(t, gotPath)
}
