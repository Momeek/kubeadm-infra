# k8s-kubeadm-infra

This is a self-managed, highly available Kubernetes cluster I built on AWS from scratch — no EKS, no managed control plane, no shortcuts. Everything from the VPC to the cluster bootstrap was done manually. The infrastructure was provisioned with Terraform and the cluster was bootstrapped using kubeadm.

The goal was simple: understand what actually happens inside a Kubernetes cluster by building one myself, the hard way.

---

## What I Built

A 6-node Kubernetes cluster running on Ubuntu 22.04 EC2 instances across two AWS availability zones:

- 1 bastion host (jump server) — the only node with a public IP
- 3 control plane nodes — for high availability
- 2 worker nodes — where workloads actually run

The cluster was first brought up at **Kubernetes v1.36**, then manually upgraded to **v1.37**.

---

## Infrastructure

I wrote the Terraform code as three modules — a root module that wires everything together, a `vpc` module, and an `ec2` module.

```
k8s-kubeadm-infra/
├── main.tf                   # root — calls vpc and ec2, passes outputs between them
├── variables.tf
├── output.tf
├── versions.tf
├── terraform.tfvars.example
├── vpc/                      # VPC, subnets, IGW, NAT gateway, route tables
└── ec2/                      # security groups, firewall rules, EC2 instances
```

The root `main.tf` has a `locals` block that defines all 6 nodes — their names, roles, subnet placement, and instance types — as a single map. That map gets passed into the ec2 module, which means the root module stays clean and adding a node is just one more entry in the map.

When you run `terraform apply`, the vpc module runs first and outputs the VPC ID and subnet IDs. The ec2 module picks those up and uses them to place instances in the right subnets and attach security groups to the right VPC. Terraform figures out the dependency order automatically.

### Network layout

```
VPC — 172.16.0.0/16
│
├── Public subnets
│   ├── az1  172.16.1.0/24   → bastion host, NAT gateway
│   └── az2  172.16.2.0/24   → reserved
│
└── Private subnets
    ├── az1  172.16.10.0/24  → control-plane1, control-plane3, worker-node1
    └── az2  172.16.11.0/24  → control-plane2, worker-node2
```

All Kubernetes nodes sit in private subnets with no public IPs. The only way in is through the bastion. The NAT gateway in az1 gives private nodes outbound internet access so they can pull packages and container images without being reachable from the outside.

### Why 3 control planes?

Kubernetes stores all cluster state in etcd, a distributed key-value store that requires a quorum — a majority of members must be healthy for the cluster to keep working. With 3 control planes, I can lose one and the cluster keeps running. With 2, losing one means losing quorum and the cluster stops accepting changes.

### Security

Every EC2 instance has its own dedicated security group. Node-to-node traffic is allowed between all cluster nodes via security group references (not CIDR ranges), so the rules stay tight and don't need updating if IPs change. The bastion can SSH into any node and reach port 6443 (the Kubernetes API) on the control planes. SSH to the bastion itself is locked to a specific trusted IP.

IMDSv2 is enforced on all instances (`http_tokens = required`), which blocks a common class of SSRF attacks against the EC2 metadata service. All root volumes are encrypted gp3, 30 GB.

---

## Bootstrapping the Cluster

### Node preparation

Before installing anything Kubernetes-related, I prepped every node the same way — loaded the `overlay` and `br_netfilter` kernel modules needed for container networking, enabled IP forwarding and bridge netfilter via sysctl, and disabled swap. Kubernetes doesn't support swap because it interferes with how the scheduler makes resource decisions.

### Container runtime

I installed containerd on all nodes as the container runtime. The important part was generating the default config and flipping `SystemdCgroup` to `true`. Without that, kubelet and containerd end up using different cgroup drivers and the node fails to start properly.

### Installing Kubernetes tools

I SSHed into each node through the bastion and installed from the official Kubernetes apt repository pinned to v1.36.

On the **control planes** I installed all three: `kubeadm`, `kubelet`, and `kubectl`.

On the **worker nodes** I only installed `kubeadm` and `kubelet` — no `kubectl`. Workers don't manage the cluster, they just run workloads, so there's no reason for kubectl to be there.

All packages were pinned with `apt-mark hold` so they wouldn't get accidentally upgraded by a routine `apt upgrade`.

### Initialising the cluster

I ran `kubeadm init` on control-plane1 with two flags:

```bash
sudo kubeadm init \
  --control-plane-endpoint "<control-plane1-private-ip>:6443" \
  --upload-certs
```

- `--control-plane-endpoint` points all nodes at control-plane1's private IP as the API server address. In a production setup this would be a load balancer, but for this cluster a direct IP is fine.
- `--upload-certs` tells kubeadm to encrypt the control plane certificates and store them in a Kubernetes secret. This meant control-plane2 and control-plane3 could pull the certs automatically when joining, without me having to manually copy files between nodes.

After init, I set up kubeconfig on control-plane1 and saved the two join commands that kubeadm printed — one for the other control planes, one for the workers.

### Joining the other control planes

I ran the `--control-plane` join command on control-plane2 and control-plane3. The `--certificate-key` in that command is a one-time key that lets the joining node decrypt and download the certificates from the secret that `--upload-certs` created. It expires after 2 hours.

### Joining the workers

I ran the plain join command on worker-node1 and worker-node2. No certificate key needed — workers just register with the API server as nodes available to run pods.

### CNI

Without a CNI plugin, all nodes sit in `NotReady` state because pod networking doesn't exist yet. I installed Cilium, which handles pod-to-pod networking and enforces network policies. After Cilium came up, all 5 nodes flipped to `Ready`.

---

## Upgrading from v1.36 to v1.37

After the cluster was stable on v1.36, I upgraded it to v1.37 manually — one node at a time, control planes first, workers last. Upgrading multiple nodes at once risks losing etcd quorum and taking the cluster down.

The upgrade sequence for each node was:

1. Switch the apt repo to v1.37
2. Upgrade `kubeadm`
3. Run the kubeadm upgrade command
4. Drain the node — gracefully evict all pods off it
5. Upgrade `kubelet` (and `kubectl` on control planes)
6. Restart `kubelet`
7. Uncordon the node — let the scheduler put pods back on it

### Control planes

On **control-plane1** I ran `kubeadm upgrade apply v1.37.0` — this is the command that actually upgrades the cluster-wide components: the API server, etcd, scheduler, and controller manager.

On **control-plane2 and control-plane3** I ran `kubeadm upgrade node` instead. Secondary control planes don't re-run the full upgrade — they just sync their local components to what control-plane1 already applied.

### Workers

Workers are simpler. `kubeadm upgrade node` on a worker just updates the kubelet configuration file to match the new cluster version. Then drain, upgrade kubelet, restart, uncordon — same pattern as the control planes but without kubectl since it was never installed on workers.

### Result

After all 5 nodes were done:

```
NAME              STATUS   ROLES           VERSION
control-plane1    Ready    control-plane   v1.37.x
control-plane2    Ready    control-plane   v1.37.x
control-plane3    Ready    control-plane   v1.37.x
worker-node1      Ready    <none>          v1.37.x
worker-node2      Ready    <none>          v1.37.x
```

---

## Terraform Outputs

After `terraform apply`, these values are available:

| Output | Description |
|---|---|
| `bastion_public_ip` | Public IP of the bastion — SSH entry point |
| `instance_private_ips` | Private IPs of all 6 nodes keyed by name |
| `instance_ids` | EC2 instance IDs keyed by name |
| `vpc_id` | VPC ID |
| `public_subnet_ids` | Public subnet IDs keyed by az1/az2 |
| `private_subnet_ids` | Private subnet IDs keyed by az1/az2 |
| `nat_gateway_id` | NAT gateway ID |
| `bastion_security_group_id` | Bastion security group ID |
| `node_security_group_ids` | Security group IDs for each cluster node |
