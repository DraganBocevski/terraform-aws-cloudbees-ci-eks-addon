.DEFAULT_GOAL   	:= help
SHELL           	:= /usr/bin/env bash
MAKEFLAGS       	+= --no-print-directory
MKFILEDIR 			:= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

define confirmation
	@echo -n "Asking for your confirmation to $(1) [yes/No] " && read ans && [ $${ans:-No} = yes ]
endef

#https://aws-ia.github.io/terraform-aws-eks-blueprints/getting-started/#deploy
define tfDeploy
	@printf "\033[36mDeploying CloudBees CI Blueprint %s...\033[0m\n\n" "$(1)"
	$(call confirmation,Deploy $(1))
	terraform -chdir=$(MKFILEDIR)/blueprints/$(1) init -upgrade
	terraform -chdir=$(MKFILEDIR)/blueprints/$(1) apply -target="module.vpc" -auto-approve
	terraform -chdir=$(MKFILEDIR)/blueprints/$(1) apply -target="module.eks" -auto-approve
	terraform -chdir=$(MKFILEDIR)/blueprints/$(1) apply -auto-approve
	@touch $(MKFILEDIR)/blueprints/$(1)/.deployed
endef

#https://aws-ia.github.io/terraform-aws-eks-blueprints/getting-started/#destroy
define tfDestroy
	@printf "\033[36mDestroying CloudBees CI Blueprint %s...\033[0m\n\n" "$(1)"
	$(call confirmation,Destroy $(1))
	$(shell cd $(MKFILEDIR)/blueprints/$(1) && terraform output --raw configure_kubectl)
	$(eval CBCI_NAMESPACE := $(shell cd blueprints/$(1) && terraform output -raw eks_blueprints_addon_cbci_namepace))
	kubectl delete --all pods --grace-period=0 --force --namespace $(CBCI_NAMESPACE) || echo "There are no pods to delete in $(shell cd blueprints/$(1) && terraform output -raw eks_blueprints_addon_cbci_namepace)" 
	terraform -chdir=$(MKFILEDIR)/blueprints/$(1) destroy -target=module.eks_blueprints_addon_cbci -auto-approve
	kubectl delete --all pvc --grace-period=0 --force --namespace $(CBCI_NAMESPACE) || echo "There are no pvc to delete in $(shell cd blueprints/$(1) && terraform output -raw eks_blueprints_addon_cbci_namepace)"
	terraform -chdir=$(MKFILEDIR)/blueprints/$(1) destroy -target=module.eks_blueprints_addons -auto-approve
	terraform -chdir=$(MKFILEDIR)/blueprints/$(1) destroy -target=module.eks -auto-approve
	terraform -chdir=$(MKFILEDIR)/blueprints/$(1) destroy -auto-approve
	@rm -f $(MKFILEDIR)/blueprints/$(1)/.deployed
endef

define validate
	@printf "\033[36mValidating CloudBees CI Operation Center availability for %s...\033[0m\n\n" "$(1)"
	$(call confirmation,Validate $(1))
	$(shell cd $(MKFILEDIR)/blueprints/$(1) && terraform output --raw configure_kubectl)
	$(eval CBCI_NAMESPACE := $(shell cd blueprints/$(1) && terraform output -raw eks_blueprints_addon_cbci_namepace))
	$(eval OC_URL := $(shell cd blueprints/$(1) && terraform output -raw cjoc_url))
	$(eval ADMIN_PASS := $(shell kubectl exec -n $(CBCI_NAMESPACE) -ti cjoc-0 -- cat /var/jenkins_home/secrets/initialAdminPassword))
	until kubectl get pod -n $(CBCI_NAMESPACE) cjoc-0; do sleep 2 && echo "Waiting for Pod to get ready"; done
	@echo "OC Pod is Ready"
	until kubectl get ing -n $(CBCI_NAMESPACE) cjoc; do sleep 2 && echo "Waiting for Ingress to get ready"; done
	@echo "Ingress Ready"
	until curl -sSf $(OC_URL)/whoAmI/api/json > /dev/null; do sleep 10 && echo "Waiting for Operation Center at $(1)"; done
	@echo "Operation Center Ready at $(OC_URL)"
	@echo "Initial Admin Password: $(ADMIN_PASS)"
endef

.PHONY: dBuildAndRun
dBuildAndRun: ## Docker Build and Run locally. Example: make dBuildAndRun 
dBuildAndRun:
	docker build . --file $(MKFILEDIR)/.docker/Dockerfile \
		--tag local.cloudbees/bp-agent:latest
	docker run -it --name bp-agent_$(shell echo $$RANDOM) \
		-v $(MKFILEDIR):/root/cloudbees-ci-addons -v $(HOME)/.aws:/root/.aws \
		local.cloudbees/bp-agent:latest

.PHONY: tfpreFlightChecks
tfpreFlightChecks: ## Run preflight checks for terraform according to getting-started/README.md . Example: ROOT=getting-started/v4 make tfpreFlightChecks 
tfpreFlightChecks: guard-ROOT
	@if [ ! -f blueprints/$(ROOT)/.auto.tfvars ]; then echo ERROR: blueprints/$(ROOT)/.auto.tfvars file does not exist and it is required that contains your own values for required variables; exit 1; fi
	$(eval USER_ID := $(shell aws sts get-caller-identity | grep UserId | cut -d"," -f 1 | xargs ))
	@if [ "$(USER_ID)" == "" ]; then echo "ERROR: AWS Authention for CLI is not configured" && exit 1; fi
	@echo "Preflight Checks OK for $(USER_ID)"

.PHONY: tfDeploy
tfDeploy: ## Deploy Terraform Blueprint passed as parameter. Example: ROOT=getting-started/v4 make tfDeploy 
tfDeploy: guard-ROOT tfpreFlightChecks
	$(call tfDeploy,$(ROOT))

.PHONY: tfDestroy
tfDestroy: ## Destroy Terraform Blueprint passed as parameter. Example: ROOT=getting-started/v4 make tfDestroy 
tfDestroy: guard-ROOT tfpreFlightChecks
ifneq (,$(wildcard blueprints/$(ROOT)/.deployed))
	$(call tfDestroy,$(ROOT))
else
	@echo "ERROR: Blueprint $(ROOT) did not complete the Deployment target"
endif

.PHONY: validate
validate: ## Validate CloudBees CI Blueprint deployment passed as parameter. Example: ROOT=getting-started/v4 make validate
validate: guard-ROOT
ifneq (,$(wildcard blueprints/$(ROOT)/.deployed))
	$(call validate,$(ROOT))
else
	@echo "ERROR: Blueprint $(ROOT) did not complete the Deployment target"
endif

.PHONY: help
help: ## Makefile Help Page
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[\/\%a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-21s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST) 2>/dev/null

.PHONY: guard-%
guard-%:
	@if [[ "${${*}}" == "" ]]; then echo "Environment variable $* not set"; exit 1; fi