output "cluster_name" {
  description = "Ім'я кластера. Знадобиться для aws eks update-kubeconfig."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Адреса сервера API."
  value       = module.eks.cluster_endpoint
}

output "cluster_region" {
  description = "Регіон кластера."
  value       = var.region
}

output "kubeconfig_command" {
  description = "Скопіюйте й виконайте, щоб налаштувати kubectl."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "Ідентифікатор VPC. Знадобиться конфігурації addons."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Публічні підмережі."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Приватні підмережі. Порожні: залишені для наступних занять."
  value       = module.vpc.private_subnets
}

output "node_scale_commands" {
  description = "Як піднімати й опускати вузли. Terraform цього не робить: модуль ігнорує зміни desired_size."
  value       = <<-EOT
    NG=$(aws eks list-nodegroups --cluster-name ${module.eks.cluster_name} --query 'nodegroups[0]' --output text)
    aws eks update-nodegroup-config --cluster-name ${module.eks.cluster_name} --nodegroup-name $NG --scaling-config desiredSize=1
    aws eks update-nodegroup-config --cluster-name ${module.eks.cluster_name} --nodegroup-name $NG --scaling-config desiredSize=0
  EOT
}
