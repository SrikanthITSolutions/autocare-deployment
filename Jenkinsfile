/*
 * AutoCare - Deployment Pipeline
 *
 * This pipeline does NOT build the Java application. The CI pipeline (in
 * autocare-platform) already handles: GitHub -> Maven -> Test -> SonarQube
 * -> Docker Build -> ECR push. This pipeline only takes an already-built,
 * already-pushed image tag from Amazon ECR and deploys it to Amazon EKS via
 * Helm.
 *
 * Only ENVIRONMENT and IMAGE_TAG ever need to be typed in by hand. Every
 * other parameter (ECR_REPOSITORY, AWS_REGION, EKS_CLUSTER_NAME, NAMESPACE,
 * IRSA_ROLE_ARN) auto-resolves from /autocare/<environment>/* in SSM
 * Parameter Store - the same values autocare-infrastructure's Terraform
 * publishes and autocare-platform's CI pipeline already reads - if left
 * blank. Pass an explicit value for any of them to override the default.
 *
 * AWS authentication: no AWS access keys are hard-coded here. Configure a
 * Jenkins credential of kind "AWS Credentials" (or use an EC2 instance
 * profile / EKS-hosted-agent IAM role, in which case the withCredentials
 * blocks below can be removed entirely and the same shell commands will
 * pick up credentials from the environment/instance metadata).
 */

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['dev', 'prod'], description: 'Target deployment environment')
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Immutable image tag already pushed to ECR by the CI pipeline (e.g. Git SHA or build number). "latest" is rejected for prod. The one value you always have to provide - everything else below auto-resolves from SSM Parameter Store if left blank.')
        string(name: 'ECR_REPOSITORY', defaultValue: '', description: 'Full ECR repository URI. Leave blank to auto-resolve from /autocare/<environment>/ecr_repository_url.')
        string(name: 'AWS_REGION', defaultValue: '', description: 'AWS region. Leave blank to auto-resolve from /autocare/<environment>/aws_region.')
        string(name: 'EKS_CLUSTER_NAME', defaultValue: '', description: 'EKS cluster name. Leave blank to auto-resolve from /autocare/<environment>/eks_cluster_name.')
        string(name: 'NAMESPACE', defaultValue: '', description: 'Kubernetes namespace to deploy into. Leave blank to auto-resolve from /autocare/<environment>/namespace.')
        string(name: 'IRSA_ROLE_ARN', defaultValue: '', description: 'IAM role ARN for the AutoCare ServiceAccount (IRSA). Leave blank to auto-resolve from /autocare/<environment>/app_irsa_role_arn.')
    }

    environment {
        RELEASE_NAME       = 'autocare'
        CHART_DIR          = 'helm/autocare'
        AWS_CREDENTIALS_ID = 'aws-autocare-creds' // Same credential used by autocare-infrastructure and autocare-platform; remove usage if relying on an instance/IRSA role instead
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Validate Environment') {
            // Only ENVIRONMENT and IMAGE_TAG are ever required as input - everything
            // else auto-resolves from the same /autocare/<environment>/* SSM
            // parameters the autocare-platform CI pipeline already reads, so a
            // manual trigger doesn't mean copy-pasting five values by hand.
            steps {
                script {
                    if (!params.IMAGE_TAG?.trim()) {
                        error "IMAGE_TAG must be provided"
                    }
                    if (params.ENVIRONMENT == 'prod' && params.IMAGE_TAG.trim().toLowerCase() == 'latest') {
                        error "The 'latest' image tag is not allowed for production deployments - use an immutable tag (Git SHA/build number)"
                    }
                    env.IMAGE_TAG        = params.IMAGE_TAG.trim()
                    env.ECR_REPOSITORY   = params.ECR_REPOSITORY?.trim()
                    env.AWS_REGION       = params.AWS_REGION?.trim()
                    env.EKS_CLUSTER_NAME = params.EKS_CLUSTER_NAME?.trim()
                    env.NAMESPACE        = params.NAMESPACE?.trim()
                    env.IRSA_ROLE_ARN    = params.IRSA_ROLE_ARN?.trim()

                    if (!env.ECR_REPOSITORY || !env.AWS_REGION || !env.EKS_CLUSTER_NAME || !env.NAMESPACE || !env.IRSA_ROLE_ARN) {
                        def ssmPath = "/autocare/${params.ENVIRONMENT}"
                        // Bootstrap region only to reach SSM itself; the actual
                        // /aws_region value from SSM wins below if AWS_REGION was blank.
                        def bootstrapRegion = env.AWS_REGION ?: 'us-east-1'
                        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                            if (!env.AWS_REGION) {
                                env.AWS_REGION = sh(script: "aws ssm get-parameter --name ${ssmPath}/aws_region --region ${bootstrapRegion} --query 'Parameter.Value' --output text", returnStdout: true).trim()
                            }
                            if (!env.ECR_REPOSITORY) {
                                env.ECR_REPOSITORY = sh(script: "aws ssm get-parameter --name ${ssmPath}/ecr_repository_url --region ${env.AWS_REGION} --query 'Parameter.Value' --output text", returnStdout: true).trim()
                            }
                            if (!env.EKS_CLUSTER_NAME) {
                                env.EKS_CLUSTER_NAME = sh(script: "aws ssm get-parameter --name ${ssmPath}/eks_cluster_name --region ${env.AWS_REGION} --query 'Parameter.Value' --output text", returnStdout: true).trim()
                            }
                            if (!env.NAMESPACE) {
                                env.NAMESPACE = sh(script: "aws ssm get-parameter --name ${ssmPath}/namespace --region ${env.AWS_REGION} --query 'Parameter.Value' --output text", returnStdout: true).trim()
                            }
                            if (!env.IRSA_ROLE_ARN) {
                                env.IRSA_ROLE_ARN = sh(script: "aws ssm get-parameter --name ${ssmPath}/app_irsa_role_arn --region ${env.AWS_REGION} --query 'Parameter.Value' --output text", returnStdout: true).trim()
                            }
                        }
                    }

                    if (!fileExists("${CHART_DIR}/values-${params.ENVIRONMENT}.yaml")) {
                        error "No values file found for environment '${params.ENVIRONMENT}' at ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml"
                    }

                    // Single-quoted on purpose: these strings are spliced unquoted into later
                    // sh scripts, and only a shell-preserved literal backslash before each dot
                    // stops Helm's --set from treating "eks.amazonaws.com" as three nested keys.
                    env.HELM_IRSA_ARGS = env.IRSA_ROLE_ARN
                        ? "--set 'serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${env.IRSA_ROLE_ARN}'"
                        : ''
                    echo "Resolved parameters: environment=${params.ENVIRONMENT}, image=${env.ECR_REPOSITORY}:${env.IMAGE_TAG}, cluster=${env.EKS_CLUSTER_NAME}, namespace=${env.NAMESPACE}, region=${env.AWS_REGION}"
                }
            }
        }

        stage('Helm Version') {
            steps {
                sh 'helm version'
            }
        }

        stage('Helm Lint') {
            steps {
                sh "helm lint ${CHART_DIR} -f ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml"
            }
        }

        stage('Helm Template') {
            steps {
                sh """
                    helm template ${RELEASE_NAME} ${CHART_DIR} \
                      --namespace ${env.NAMESPACE} \
                      -f ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml \
                      --set image.repository=${env.ECR_REPOSITORY} \
                      --set image.tag=${env.IMAGE_TAG} \
                      ${HELM_IRSA_ARGS} \
                      > rendered-manifests.yaml
                """
                archiveArtifacts artifacts: 'rendered-manifests.yaml', fingerprint: true
            }
        }

        stage('AWS Authentication') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh 'aws sts get-caller-identity --region ' + env.AWS_REGION
                }
            }
        }

        stage('Update Kubeconfig') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "aws eks update-kubeconfig --name ${env.EKS_CLUSTER_NAME} --region ${env.AWS_REGION}"
                }
            }
        }

        stage('Verify EKS Access') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh 'kubectl get nodes'
                }
            }
        }

        stage('Verify ECR Image') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    script {
                        def repoName = env.ECR_REPOSITORY.tokenize('/').last()
                        def status = sh(
                            script: "aws ecr describe-images --repository-name ${repoName} --image-ids imageTag=${env.IMAGE_TAG} --region ${env.AWS_REGION}",
                            returnStatus: true
                        )
                        if (status != 0) {
                            error "Image tag '${env.IMAGE_TAG}' was not found in ECR repository '${repoName}'. Deployment aborted."
                        }
                        echo "Confirmed image ${repoName}:${env.IMAGE_TAG} exists in ECR"
                    }
                }
            }
        }

        stage('Helm Dry Run') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh """
                        helm upgrade --install ${RELEASE_NAME} ${CHART_DIR} \
                          --namespace ${env.NAMESPACE} \
                          --create-namespace \
                          -f ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml \
                          --set image.repository=${env.ECR_REPOSITORY} \
                          --set image.tag=${env.IMAGE_TAG} \
                          ${HELM_IRSA_ARGS} \
                          --dry-run
                    """
                }
            }
        }

        stage('Helm Upgrade / Install') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh """
                        helm upgrade --install ${RELEASE_NAME} ${CHART_DIR} \
                          --namespace ${env.NAMESPACE} \
                          --create-namespace \
                          -f ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml \
                          --set image.repository=${env.ECR_REPOSITORY} \
                          --set image.tag=${env.IMAGE_TAG} \
                          ${HELM_IRSA_ARGS} \
                          --wait \
                          --atomic \
                          --timeout 10m
                    """
                }
            }
        }

        stage('Wait for Rollout') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "kubectl rollout status deployment/${RELEASE_NAME} -n ${env.NAMESPACE} --timeout=300s"
                }
            }
        }

        stage('Verify Pods') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "chmod +x scripts/verify.sh && ./scripts/verify.sh ${env.NAMESPACE}"
                }
            }
        }

        stage('Verify Service') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "kubectl get svc ${RELEASE_NAME} -n ${env.NAMESPACE}"
                }
            }
        }

        stage('Verify Ingress') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "kubectl get ingress ${RELEASE_NAME} -n ${env.NAMESPACE}"
                }
            }
        }

        stage('Display Application Information') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh """
                        echo '===================================================='
                        echo ' AutoCare Deployment Summary'
                        echo '===================================================='
                        echo " Environment : ${params.ENVIRONMENT}"
                        echo " Image       : ${env.ECR_REPOSITORY}:${env.IMAGE_TAG}"
                        echo " Namespace   : ${env.NAMESPACE}"
                        echo " Cluster     : ${env.EKS_CLUSTER_NAME}"
                        ALB_HOST=\$(kubectl get ingress ${RELEASE_NAME} -n ${env.NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
                        if [ -n "\$ALB_HOST" ]; then
                          echo " Application URL: http://\$ALB_HOST"
                        else
                          echo " ALB hostname not yet available - check again in a few minutes with:"
                          echo "   kubectl get ingress ${RELEASE_NAME} -n ${env.NAMESPACE}"
                        fi
                        echo '===================================================='
                    """
                }
            }
        }
    }

    post {
        failure {
            echo "Deployment FAILED. To roll back to the previous successful release, run:"
            echo "  ./scripts/rollback.sh ${env.NAMESPACE}"
        }
        always {
            sh 'rm -f rendered-manifests.yaml || true'
        }
    }
}
