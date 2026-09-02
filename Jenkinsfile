/*
 * AutoCare - Deployment Pipeline
 *
 * This pipeline does NOT build the Java application. The CI pipeline (in
 * autocare-platform) already handles: GitHub -> Maven -> Test -> SonarQube
 * -> Docker Build -> ECR push. This pipeline only takes an already-built,
 * already-pushed image tag from Amazon ECR and deploys it to Amazon EKS via
 * Helm.
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
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Immutable image tag already pushed to ECR by the CI pipeline (e.g. Git SHA or build number). "latest" is rejected for prod.')
        string(name: 'ECR_REPOSITORY', defaultValue: '', description: 'Full ECR repository URI, e.g. <account-id>.dkr.ecr.us-east-1.amazonaws.com/autocare')
        string(name: 'AWS_REGION', defaultValue: 'us-east-1', description: 'AWS region')
        string(name: 'EKS_CLUSTER_NAME', defaultValue: '', description: 'EKS cluster name, e.g. autocare-dev-eks')
        string(name: 'NAMESPACE', defaultValue: 'autocare', description: 'Kubernetes namespace to deploy into')
        string(name: 'IRSA_ROLE_ARN', defaultValue: '', description: 'IAM role ARN for the AutoCare ServiceAccount (IRSA), e.g. arn:aws:iam::<account>:role/autocare-dev-secrets-role. Leave empty to fall back to whatever is already in the values file (not recommended - Secrets Manager access will fail without it).')
    }

    environment {
        RELEASE_NAME       = 'autocare'
        CHART_DIR          = 'helm/autocare'
        AWS_CREDENTIALS_ID = 'aws-eks-deployer' // Jenkins credential id (AWS Credentials kind); remove usage if relying on an instance/IRSA role instead
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Validate Environment') {
            steps {
                script {
                    if (!params.IMAGE_TAG?.trim()) {
                        error "IMAGE_TAG must be provided"
                    }
                    if (params.ENVIRONMENT == 'prod' && params.IMAGE_TAG.trim().toLowerCase() == 'latest') {
                        error "The 'latest' image tag is not allowed for production deployments - use an immutable tag (Git SHA/build number)"
                    }
                    if (!params.ECR_REPOSITORY?.trim()) {
                        error "ECR_REPOSITORY must be provided"
                    }
                    if (!params.EKS_CLUSTER_NAME?.trim()) {
                        error "EKS_CLUSTER_NAME must be provided"
                    }
                    if (!fileExists("${CHART_DIR}/values-${params.ENVIRONMENT}.yaml")) {
                        error "No values file found for environment '${params.ENVIRONMENT}' at ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml"
                    }
                    // Single-quoted on purpose: these strings are spliced unquoted into later
                    // sh scripts, and only a shell-preserved literal backslash before each dot
                    // stops Helm's --set from treating "eks.amazonaws.com" as three nested keys.
                    env.HELM_IRSA_ARGS = params.IRSA_ROLE_ARN?.trim()
                        ? "--set 'serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${params.IRSA_ROLE_ARN.trim()}'"
                        : ''
                    echo "Validated parameters for environment=${params.ENVIRONMENT}, image=${params.ECR_REPOSITORY}:${params.IMAGE_TAG}"
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
                      --namespace ${params.NAMESPACE} \
                      -f ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml \
                      --set image.repository=${params.ECR_REPOSITORY} \
                      --set image.tag=${params.IMAGE_TAG} \
                      ${HELM_IRSA_ARGS} \
                      > rendered-manifests.yaml
                """
                archiveArtifacts artifacts: 'rendered-manifests.yaml', fingerprint: true
            }
        }

        stage('AWS Authentication') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh 'aws sts get-caller-identity --region ' + params.AWS_REGION
                }
            }
        }

        stage('Update Kubeconfig') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "aws eks update-kubeconfig --name ${params.EKS_CLUSTER_NAME} --region ${params.AWS_REGION}"
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
                        def repoName = params.ECR_REPOSITORY.tokenize('/').last()
                        def status = sh(
                            script: "aws ecr describe-images --repository-name ${repoName} --image-ids imageTag=${params.IMAGE_TAG} --region ${params.AWS_REGION}",
                            returnStatus: true
                        )
                        if (status != 0) {
                            error "Image tag '${params.IMAGE_TAG}' was not found in ECR repository '${repoName}'. Deployment aborted."
                        }
                        echo "Confirmed image ${repoName}:${params.IMAGE_TAG} exists in ECR"
                    }
                }
            }
        }

        stage('Helm Dry Run') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh """
                        helm upgrade --install ${RELEASE_NAME} ${CHART_DIR} \
                          --namespace ${params.NAMESPACE} \
                          --create-namespace \
                          -f ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml \
                          --set image.repository=${params.ECR_REPOSITORY} \
                          --set image.tag=${params.IMAGE_TAG} \
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
                          --namespace ${params.NAMESPACE} \
                          --create-namespace \
                          -f ${CHART_DIR}/values-${params.ENVIRONMENT}.yaml \
                          --set image.repository=${params.ECR_REPOSITORY} \
                          --set image.tag=${params.IMAGE_TAG} \
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
                    sh "kubectl rollout status deployment/${RELEASE_NAME} -n ${params.NAMESPACE} --timeout=300s"
                }
            }
        }

        stage('Verify Pods') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "chmod +x scripts/verify.sh && ./scripts/verify.sh ${params.NAMESPACE}"
                }
            }
        }

        stage('Verify Service') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "kubectl get svc ${RELEASE_NAME} -n ${params.NAMESPACE}"
                }
            }
        }

        stage('Verify Ingress') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
                    sh "kubectl get ingress ${RELEASE_NAME} -n ${params.NAMESPACE}"
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
                        echo " Image       : ${params.ECR_REPOSITORY}:${params.IMAGE_TAG}"
                        echo " Namespace   : ${params.NAMESPACE}"
                        echo " Cluster     : ${params.EKS_CLUSTER_NAME}"
                        ALB_HOST=\$(kubectl get ingress ${RELEASE_NAME} -n ${params.NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
                        if [ -n "\$ALB_HOST" ]; then
                          echo " Application URL: http://\$ALB_HOST"
                        else
                          echo " ALB hostname not yet available - check again in a few minutes with:"
                          echo "   kubectl get ingress ${RELEASE_NAME} -n ${params.NAMESPACE}"
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
            echo "  ./scripts/rollback.sh ${params.NAMESPACE}"
        }
        always {
            sh 'rm -f rendered-manifests.yaml || true'
        }
    }
}
