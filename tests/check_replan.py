#!/usr/bin/env python3
"""Check real lifecycle behavior from synthetic native-test state, without AWS.

All AWS endpoints used by the plans are bounded loopback fixtures. Credentials
and secret values are synthetic. The state originates only in native mock tests.
It never loads user state, credentials or installation inputs. Run with Python3 and
TERRAFORM_BIN pointing at Terraform >=1.11 (qualified with 1.13.4).
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from urllib.parse import parse_qs
import os
from pathlib import Path
import shutil
import subprocess

MODULE = Path(__file__).resolve().parents[1]
TF = os.environ.get("TERRAFORM_BIN") or shutil.which("terraform")
if not TF:
    raise SystemExit("Set TERRAFORM_BIN to a Terraform >=1.11 executable")
WORK = MODULE / ".terraform" / "replan"
WORK.mkdir(parents=True, exist_ok=True)
ENV = dict(os.environ, AWS_CONFIG_FILE=os.devnull, AWS_SHARED_CREDENTIALS_FILE=os.devnull,
           AWS_EC2_METADATA_DISABLED="true", AWS_ACCESS_KEY_ID="synthetic-test-only",
           AWS_SECRET_ACCESS_KEY="synthetic-test-only", AWS_SESSION_TOKEN="")


def run(path, *args):
    result = subprocess.run([TF, f"-chdir={path}", *args], env=ENV, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (WORK / f"{args[0]}.log").write_text(result.stdout[-6000:])
    if result.returncode:
        raise SystemExit(result.stdout[-6000:])
    return result.stdout


class MetadataFixture(BaseHTTPRequestHandler):
    """Only these exact non-business metadata reads are admitted."""
    def log_message(self, *_args):
        pass

    def do_POST(self):
        request = self.rfile.read(int(self.headers["Content-Length"])).decode()
        content_type = "text/xml"
        params = parse_qs(request)
        action = params.get("Action", [""])[0]
        if self.headers.get("X-Amz-Target") == "secretsmanager.GetSecretValue":
            arn = json.loads(request)["SecretId"]
            if arn not in {facts["redis"]["secret_arn"], exporter_secret_arn}:
                self.send_error(400, "Unadmitted secret reference")
                return
            body = json.dumps({"ARN": arn, "SecretString": json.dumps({"password": "synthetic-redis-password"})})
            content_type = "application/x-amz-json-1.1"
        elif action == "GetCallerIdentity":
            body = '<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult><Account>111111111111</Account><Arn>arn:aws:iam::111111111111:role/synthetic-test</Arn><UserId>synthetic</UserId></GetCallerIdentityResult><ResponseMetadata><RequestId>synthetic</RequestId></ResponseMetadata></GetCallerIdentityResponse>'
        elif action == "DescribeSubnets":
            subnet = params.get("SubnetId.1", [""])[0]
            if subnet not in {"subnet-12345678", "subnet-87654321"}:
                self.send_error(400, "Unadmitted subnet")
                return
            zone = "us-west-2a" if subnet == "subnet-12345678" else "us-west-2b"
            body = f'<DescribeSubnetsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/"><requestId>synthetic</requestId><subnetSet><item><subnetId>{subnet}</subnetId><state>available</state><vpcId>vpc-12345678</vpcId><cidrBlock>10.0.0.0/24</cidrBlock><availabilityZone>{zone}</availabilityZone><mapPublicIpOnLaunch>false</mapPublicIpOnLaunch><availableIpAddressCount>250</availableIpAddressCount></item></subnetSet></DescribeSubnetsResponse>'
        else:
            self.send_error(400, "Unadmitted action")
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body.encode())


exporter_secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:ecs-fixture-exporter-AbCdEf"
server = ThreadingHTTPServer(("127.0.0.1", 0), MetadataFixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
endpoint = f"http://127.0.0.1:{server.server_address[1]}"

native = run(MODULE, "test", "-filter=tests/services.tftest.hcl", "-verbose", "-json")
state_view = next(json.loads(line)["test_state"] for line in native.splitlines() if '"test_state"' in line)
resources = {}
for resource in state_view["root_module"]["resources"]:
    attrs = resource["values"]
    if "region" in attrs:
        attrs["region"] = "us-west-2"
    if resource["type"] == "aws_ecs_service" and resource.get("index") == "sampler":
        attrs["desired_count"] = 2
    key = (resource["mode"], resource["type"], resource["name"])
    entry = resources.setdefault(key, {"module": "module.ecs", "mode": key[0],
        "type": key[1], "name": key[2], "provider": f'provider["{resource["provider_name"]}"]',
        "instances": []})
    instance = {"schema_version": resource["schema_version"], "attributes": attrs,
                "sensitive_attributes": []}
    if "index" in resource:
        instance["index_key"] = resource["index"]
    entry["instances"].append(instance)
state = {"version": 4, "terraform_version": "1.13.4", "serial": 1,
         "lineage": "ffae6477-06f9-4970-8c13-f7f82412d0db", "outputs": {},
         "resources": list(resources.values())}
(WORK / "terraform.tfstate").write_text(json.dumps(state))
main_config = '''terraform {
  required_providers { aws = { source = "hashicorp/aws", version = ">= 6.71, < 7.0" } }
}
provider "aws" {
  region = "us-west-2"
  access_key = "synthetic-test-only"
  secret_key = "synthetic-test-only"
  skip_credentials_validation = true
  skip_metadata_api_check = true
  skip_requesting_account_id = true
  skip_region_validation = true
  endpoints {
    sts = "http://127.0.0.1:9"
    ecs = "http://127.0.0.1:9"
    ec2 = "http://127.0.0.1:9"
    iam = "http://127.0.0.1:9"
    applicationautoscaling = "http://127.0.0.1:9"
    cloudwatch = "http://127.0.0.1:9"
    cloudwatchlogs = "http://127.0.0.1:9"
    secretsmanager = "http://127.0.0.1:9"
  }
}
variable "facts" { type = any }
module "ecs" {
  source = ''' + json.dumps(str(MODULE)) + '''
  providers = {aws=aws, aws.secrets=aws}
  application_environment = merge({for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker"] : role => {GAI_NOTIFICATION_TENANT = "synthetic-tenant"}}, {"data-pipelines"={DP_TENANT="synthetic-tenant"}})
  installation_facts = var.facts
  vpc_id = "vpc-12345678"
  private_subnet_ids = ["subnet-12345678", "subnet-87654321"]
  provision_redis = false
  existing_redis_verified = true
  existing_redis_security_group_id = "sg-12345678"
  exporter_redis_secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:ecs-fixture-exporter-AbCdEf"
  capacity = {for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines"] : role => {
    existing_provider="ecs-${role}", max_instances=3, root_volume_gib=200,
    reservation_proof={review_reference="synthetic-proof",reserved_tasks=3,independent_child_capacity=true,zero_bootstrap_supported=true}
  }}
}
'''
(WORK / "main.tf").write_text(main_config.replace("http://127.0.0.1:9", endpoint))
facts = json.loads((MODULE / "tests/fixtures/installation.json").read_text())
varfile = WORK / "synthetic.auto.tfvars.json"
varfile.write_text(json.dumps({"facts": facts}))
run(WORK, "init", "-backend=false", "-input=false", "-no-color")


def plan(name):
    run(WORK, "plan", "-refresh=false", "-input=false", "-no-color", f"-out={name}")
    return json.loads(run(WORK, "show", "-json", name))


def change(p, address):
    return next(r for r in p["resource_changes"] if r["address"] == address)["change"]


service = 'module.ecs.aws_ecs_service.worker["sampler"]'
ordinary = plan("ordinary.tfplan")
assert change(ordinary, service)["after"]["desired_count"] == 2, "Replan reset autoscaled count"
original_image = facts["pools"][0]["image_digest"]
facts["pools"][0]["image_digest"] = original_image.split("@sha256:")[0] + "@sha256:" + "b" * 64
varfile.write_text(json.dumps({"facts": facts}))
updated = plan("updated.tfplan")
assert change(updated, service)["after"]["desired_count"] == 2, "Image rollout reset autoscaled count"
definition = change(updated, 'module.ecs.aws_ecs_task_definition.worker["sampler"]')
assert json.loads(definition["before"]["container_definitions"])[0]["image"] == original_image
assert "create" in definition["actions"], "New image digest did not replace task definition"
assert json.loads(definition["after"]["container_definitions"])[0]["image"] == facts["pools"][0]["image_digest"]
print("PASS: ordinary replan preserves autoscaled2; new digest changes task definition and preserves2")

# Omit the choice entirely to exercise the shipping defaults, including actual
# ephemeral Secrets Manager reads. Refresh stays disabled and all reads are local.
(WORK / "main.tf").write_text(main_config.replace("http://127.0.0.1:9", endpoint).replace("  provision_redis = false\n", ""))
default = plan("default-elasticache.tfplan")
elasticache = change(default, "module.ecs.aws_elasticache_replication_group.main[0]")["after"]
assert elasticache["automatic_failover_enabled"] and elasticache["transit_encryption_enabled"]
assert not any(resource["type"] == "aws_efs_file_system" for resource in default["resource_changes"])
print("PASS: omitting the Redis backend still provisions Multi-AZ TLS ElastiCache alone")

server.shutdown()
