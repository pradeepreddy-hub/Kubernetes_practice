#!/bin/bash
# =============================================================================
# setup-monitoring.sh
# Sets up Prometheus + Grafana on an EKS cluster
# Usage: ./setup-monitoring.sh
# =============================================================================

set -e  # Stop script if any command fails

# -------------------------------------------------------
# CONFIGURATION - Change these values as needed
# -------------------------------------------------------
CLUSTER_NAME="demo-eks-cluster"
REGION="ap-south-1"
NODEGROUP_NAME="managed-ng"
NODE_TYPE="t3.small"
GRAFANA_PASSWORD="admin123"
NAMESPACE="monitoring"

# -------------------------------------------------------
# STEP 1: Create EKS Cluster
# Why: We need a Kubernetes cluster to deploy everything on
# -------------------------------------------------------
echo ""
echo "==> STEP 1: Creating EKS cluster..."
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --nodegroup-name $NODEGROUP_NAME \
  --node-type $NODE_TYPE \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed

echo "✅ Cluster created!"

# -------------------------------------------------------
# STEP 2: Attach EBS policy to Node Role
# Why: EBS CSI driver needs permission to create EBS volumes
#      for Prometheus to store metrics data
# -------------------------------------------------------
echo ""
echo "==> STEP 2: Attaching EBS policy to node role..."

NODE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $NODEGROUP_NAME \
  --region $REGION \
  --query 'nodegroup.nodeRole' \
  --output text | awk -F'/' '{print $NF}')

echo "    Node Role: $NODE_ROLE"

aws iam attach-role-policy \
  --role-name $NODE_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

echo "✅ EBS policy attached!"

# -------------------------------------------------------
# STEP 3: Install EBS CSI Driver
# Why: This is the bridge between Kubernetes and AWS EBS storage
#      Prometheus needs this to save metrics to disk
# -------------------------------------------------------
echo ""
echo "==> STEP 3: Installing EBS CSI Driver addon..."

eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --force

echo "    Waiting for EBS CSI Driver to become ACTIVE..."
while true; do
  STATUS=$(eksctl get addon \
    --cluster $CLUSTER_NAME \
    --region $REGION \
    2>/dev/null | grep aws-ebs-csi-driver | awk '{print $3}')
  echo "    Status: $STATUS"
  if [ "$STATUS" = "ACTIVE" ]; then
    break
  fi
  sleep 15
done

echo "✅ EBS CSI Driver is ACTIVE!"

# -------------------------------------------------------
# STEP 4: Add Helm Repos
# Why: Helm is a package manager for Kubernetes
#      We need these repos to install Prometheus and Grafana
# -------------------------------------------------------
echo ""
echo "==> STEP 4: Adding Helm repos..."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

echo "✅ Helm repos added!"

# -------------------------------------------------------
# STEP 5: Create Monitoring Namespace
# Why: Keeps all monitoring tools isolated in one namespace
#      instead of mixing with application pods
# -------------------------------------------------------
echo ""
echo "==> STEP 5: Creating monitoring namespace..."

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Namespace ready!"

# -------------------------------------------------------
# STEP 6: Install Prometheus
# Why: Prometheus collects and stores metrics from all pods,
#      nodes, and Kubernetes objects like HPA
# -------------------------------------------------------
echo ""
echo "==> STEP 6: Installing Prometheus..."

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace $NAMESPACE \
  --set server.persistentVolume.storageClass=gp2 \
  --set alertmanager.enabled=false \
  --wait

echo "✅ Prometheus installed!"

# -------------------------------------------------------
# STEP 7: Install Grafana
# Why: Grafana reads metrics from Prometheus and displays
#      them as visual dashboards and graphs
# -------------------------------------------------------
echo ""
echo "==> STEP 7: Installing Grafana..."

helm upgrade --install grafana grafana/grafana \
  --namespace $NAMESPACE \
  --set adminPassword=$GRAFANA_PASSWORD \
  --set service.type=LoadBalancer \
  --set persistence.enabled=true \
  --set persistence.storageClassName=gp2 \
  --wait

echo "✅ Grafana installed!"

# -------------------------------------------------------
# STEP 8: Print access details
# -------------------------------------------------------
echo ""
echo "============================================"
echo "✅ SETUP COMPLETE!"
echo "============================================"
echo ""
echo "Waiting for Grafana LoadBalancer URL..."
sleep 30

GRAFANA_URL=$(kubectl get svc grafana -n $NAMESPACE \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo ""
echo "📊 Grafana:"
echo "   URL:      http://$GRAFANA_URL"
echo "   Username: admin"
echo "   Password: $GRAFANA_PASSWORD"
echo ""
echo "📈 Prometheus (internal):"
echo "   URL: http://prometheus-server.$NAMESPACE.svc.cluster.local:80"
echo ""
echo "============================================"
echo "NEXT STEPS IN GRAFANA:"
echo "============================================"
echo "1. Login to Grafana"
echo "2. Go to Connections -> Data Sources -> Add -> Prometheus"
echo "3. URL: http://prometheus-server.$NAMESPACE.svc.cluster.local:80"
echo "4. Click Save & Test"
echo "5. Import dashboard ID: 6417 (Kubernetes Pods + HPA)"
echo "6. Import dashboard ID: 3662 (Kubernetes Cluster Overview)"
echo "============================================"
