# etcd fixtures

`kv.proto` is etcd's `api/mvccpb/kv.proto`, unmodified.
`rpc.proto` is a subset of etcd's `api/etcdserverpb/rpc.proto`: the messages
this repository's etcd trial models, with etcd's field numbers and types
unchanged. The changes are the ones that make the subset standalone:

- unused messages and every `service` block removed
- the imports for `authpb`, `versionpb`, and the grpc-gateway annotations
  dropped along with them
- the `option (...)` lines that referenced those packages removed
- the `mvccpb` import rewritten to the local `etcd/kv.proto`

Both files are Apache-2.0, from <https://github.com/etcd-io/etcd>.

The `*.txt` files are text-format messages; each names its `.proto` and message
type on the first two lines, and `just proto` runs `protoc --encode` over it and
writes the result into `../fixtures.txtar`, hex encoded. The archive is
committed, so the tests need no `protoc` at run time.
