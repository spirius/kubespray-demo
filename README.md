# Bare-Metal Kubernetes Cluster with Cilium

This repository contains the automation scripts for bootstrapping a kubernetes cluster with 5 nodes using **kubespray**.

## Design Notes

- Kubespray chosen for vanilla upstream Kubernetes + Ansible-native, fully reproducible IaC (over hand-rolled kubeadm or an opinionated distro like Talos/k3s).
- It deploys 3 control plane nodes and 2 worker nodes.
- Cilium is used as the CNI.
- kube-proxy is disabled in favor of Cilium eBPF based solution.
- Cilium tunnel mode = VXLAN because nodes are in different subnets with no shared L2. Native/direct routing isn't possible.
- WireGuard based encryption is enabled on Cilium because the nodes communicate over public IPs.
- GatewayAPI is used for traffic routing and it runs in HostNetwork mode to serve the external traffic directly on ports 80/443.
- Firewall rules are configured to only allow ports 22, 80 and 443 for any external hosts, inter-host traffic is allowed and port 6443 is only allowed from administrative IPs (your IP).

## Tradeoffs and limitations

- No floating control-plane VIP (no shared L2 / BGP / cloud API): kubeconfig targets one control-plane public IP; HA via SSH tunnel or local HAProxy. Internal control-plane HA still works (per-node API load-balancer).
- No cloud LB / MetalLB / LB-IPAM (nothing to L2/BGP-announce): ingress runs host-network on node public IPs. Production: dedicate gateway nodes + DNS to them.
- Gateway binds 80/443 on all nodes incl. control plane; production would restrict to labeled gateway nodes.
- No TLS yet -> production needs cert-manager (or similar) for 443.
- VXLAN + WireGuard double-encapsulation lowers pod MTU (~1370) and adds throughput overhead (the fragmentation note above is a symptom).
- Backend pods see Envoy as the source, not the external client. Real client IP only in X-Forwarded-For. Source-CIDR filtering belongs at the firewall/gateway, not pod NetworkPolicy.
- Standard NetworkPolicy is L3/L4 only. L7 rules and ICMP need CiliumNetworkPolicy.

# Usage

Initialize the repository and install dependencies.

```bash
source init.sh
```

Copy `inventory/assignment/inventory.example.ini` to `inventory/assignment/inventory.ini` and adjust the IP addresses of the nodes accordingly.

Make sure to add your IP address to get remote access to kubernetes control plane.

## Cluster setup

First run the `init` playbook to setup firewall rules on all hosts.

```bash
ansible-playbook -i inventory/assignment/inventory.ini playbooks/init.yml
```

Deploy the cluster with kubespray.

```bash
cd kubespray
ansible-playbook -i ../inventory/assignment/inventory.ini cluster.yml
```

## Validation Steps

```bash
kubectl get nodes
```

![kubectl get nodes](/assets/get-nodes.png)

```bash
cilium status --wait
```

![cilium status](/assets/cilium-status.png)

```bash
cilium connectivity test --test '!no-unexpected-packet-drops,!check-log-errors'
```

![cilium connectivity test](/assets/cilium-connectivity-test.png)

> **_NOTE:_** `no-unexpected-packet-drops` test is skipped as the wireguard + vxlan based setup hits this [issue](https://github.com/cilium/cilium/issues/25709). This is not a permanent problem and PMTU discovery will adjust the MTU for further packets.

> **_NOTE:_** `check-log-errors` test is skipped because two warnings are treated as errors. Specifically `Gateway API host networking is enabled, externalTrafficPolicy will be ignored`, but this is by design. And `level=warn msg="unable to re-allocate ingress IPv4." module=agent.controlplane.agent-infra-endpoints error="provided IP is not in the valid range. The range of valid IPs is 10.233.64.0/24"`, which is a known issue when pod CIDRs are reassigned across re-installs.

Node usage can be verified by

```bash
kubectl top nodes
```

![top nodes](/assets/kubectl-top-nodes.png)

## Network troubleshooting

`cilium-dbg` utility can be use for troubleshooting network issues.

First, identify the specific node to monitor and run `cilium-dbg monitor`

```bash
kubectl -n kube-system get pod -l k8s-app=cilium -o wide
kubectl -n kube-system exec cilium-tmmx4 -- cilium-dbg monitor --type drop
```

![cilium-dbg-monitor](/assets/cilium-dbg-monitor.png)

Use `cilium-dbg endpoint list` / `status` / `encrypt status` for analyzing cilium state.

## Cluster Access

kubespray saves kubernetes config file with admin access at `/etc/kubernetes/admin.conf`. Copy the config file to your local machine for remote access.

```bash
scp root@$IP1:/etc/kubernetes/admin.conf ~/.kube/range.conf
```

# Cluster Maintenance

The node management can be performed using kubespray functionality.

More details and options can be found [here](https://github.com/kubernetes-sigs/kubespray/blob/v2.30.0/docs/operations/nodes.md).

## Adding a node

Add the new node in the inventory file and run:

```bash
cd kubespray
ansible-playbook -i ../inventory/assignment/inventory.ini scale.yml
```

You can also specifically target the new node without disturbing the cluster by first running:

```bash
cd kubespray
ansible-playbook -i ../inventory/assignment/inventory.ini playbooks/facts.yml
ansible-playbook -i ../inventory/assignment/inventory.ini scale.yml --limit=NODE_NAME
```

## Removing a node

To remove a node, first run kubespray to gracefully remove it from the cluster:

```bash
cd kubespray
ansible-playbook -i ../inventory/assignment/inventory.ini remove.yml -e node=NODE_NAME
```

After that remove the node from the inventory.

# Testing

## Internal Communication

Create the client and server pods, service and network policy.

```bash
kubectl apply -f ./manifests/01-internal-connectivity.yml
```

This creates:

- 2 client pods (client and client-8080).
- 1 server pod (http echo), that runs on ports 80 and 8080
- 1 service connected to the server pods
- 2 network policies, one allowing the client to reach port 80 of the server, and another allowing the client-8080 to reach port 8080 of the server

```bash
kubectl get pods -o wide
```

![pod to pod status](/assets/pod-to-pod-status.png)

Verify pod-to-pod communication

```bash
# Get the server pod IP
S_IP=$(kubectl get pod echo -o jsonpath='{.status.podIP}')

kubectl exec client -- curl -s --max-time 5 "http://$S_IP/"
kubectl exec client -- curl -s --max-time 5 "http://$S_IP:8080/"
```

![pod to pod success](/assets/client-to-server-success.png)

![pod to pod blocked](/assets/client-to-server-blocked.png)

Verify pod-to-service communication

```bash
kubectl exec client -- curl -s --max-time 5 "http://echo/"
kubectl exec client -- curl -s --max-time 5 "http://echo:8080/"
```

![pod to service success](/assets/client-to-service-success.png)

![pod to service blocked](/assets/client-to-service-blocked.png)

Verify pod-to-pod connectivity for port 8080

```bash
kubectl exec client-8080 -- curl -s --max-time 5 "http://echo/"
kubectl exec client-8080 -- curl -s --max-time 5 "http://echo:8080/"
```

![pod 8080 to service blocked](/assets/client-8080-to-server-blocked.png)

![pod 8080 to service success](/assets/client-8080-to-server-success.png)

## External Communication

This cluster does not have any external / cloud load balancer. The HTTP(S) server is exposed on the nodes directly. In production setup dedicated nodes should be allocated for the GatewayAPI and a DNS record pointing to those nodes should be configured, as well as cert-manager (or similar) is needed for HTTPS service.

In current setup all nodes (including control plane) run GatewayAPI on host network.

Deploy echo service exposed via GatewayAPI to internet on port 80:

```bash
kubectl apply -f manifests/02-external-connectivity.yml
```

Test the connectivity

```bash
curl $IP1
```

![external connection](/assets/external-connection.png)
