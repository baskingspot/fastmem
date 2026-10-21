# infra

This directory holds the durable AWS resources and the box image of the
benchmark fleet. The harness in `bench/` launches and terminates the
instances through the EC2 API.

## Layout

| Path | Content | Who applies it |
|---|---|---|
| `iam/` | Root stack: the IAM user, its EC2 policy, one access key, and the reaper | A human |
| `iam/write-credentials.sh` | Writes the access key to `~/.aws/credentials` | A human |
| `base/` | Root stack: security group, key pair, launch templates | The bench profile |
| `base/image.nix` | The fastmem NixOS module that the box configuration imports | `base/` puts it in `user_data` |
| `modules/bench-iam/` | Module: `policy.tf` (the user policy), `reaper.tf` and `reaper/` (the reaper) | `iam/` uses it |
| `modules/bench-base/` | Module: launch templates, and `image.nix.tftpl` (the box configuration with the TTL guard) | `base/` uses it |

## Configuration

Each root stack sets `project`, `region`, and `account_id` in `locals`. The
values are `fastmem-bench`, `us-west-2`, and `396684171460`. `project` and
`region` must be equal to `project.name` and `project.region` in
`bench.toml`. The harness test suite checks that. The AWS provider refuses
every other account.

The instance allowlist is `instance_families` in `iam/main.tf`. It does not
come from `bench.toml`. The agent can edit `bench.toml`, and a cost control
must not follow a file that the agent edits.

## Prerequisites

- Run each command from the repository root.
- Run each tool from the devshell. Enter it with `nix develop`, or put
  `nix develop -c` before each command.

## The lifetime guarantee

Two mechanisms stop a box. The reaper is the guarantee. The TTL guard is the
fast path.

| Mechanism | Where it runs | Who controls it |
|---|---|---|
| Reaper | A Lambda function, outside the boxes | The `iam/` stack (a human) |
| TTL guard | Each box, from the launch template | The bench user (a human or an agent) |

The bench user writes the launch templates. Thus it controls the
`user_data`, the shutdown behavior, and the metadata options of a box. It
can also write any `ExpiresAt` value. So a box without the TTL guard, or
with a very late `ExpiresAt`, is possible. The reaper does not depend on
the box or on the bench user.

EventBridge runs the reaper every 5 minutes. The reaper terminates each
instance with the project `Project` tag if one of these conditions is true:

- The instance is `stopped` or `stopping`.
- The instance has no `ExpiresAt` tag, or the tag is not an RFC 3339 UTC
  time such as `2026-09-24T04:00:00Z`.
- The current time is after `ExpiresAt`.
- The current time is after `LaunchTime` plus `reaper_max_lifetime_hours`.
  The default is 24 hours.

Thus an instance stops at `min(ExpiresAt, LaunchTime + 24h)`, plus at most
one reaper interval. The harness limits a TTL to `fleet.max_ttl`, 12 hours
by default. Only `bench extend` can move `ExpiresAt` past the 24-hour limit,
and the limit still applies. If an instance has termination protection, the
reaper removes it and then terminates the instance.

The reaper also deletes orphans. An orphan is a volume or a network
interface that stays after its instance, because `DeleteOnTermination` is
`false`.

- The reaper deletes a project volume that is `available` and older than
  10 minutes.
- The reaper tags a project network interface that is `available` with
  `OrphanSeenAt`. It deletes the interface 10 minutes after that tag. EC2
  does not record the creation time of a network interface.

The IAM policy keeps each resource visible to the reaper:

- The tag keys must have the exact case. IAM compares the key of
  `aws:RequestTag/Project` without case. Without an `aws:TagKeys` condition,
  a `PROJECT` tag passes the policy, and exact filters do not find it.
- The bench user cannot delete `Project` or `ExpiresAt`, in any case.
- The bench user cannot stop or start an instance. A stopped box does not
  run its TTL guard, and a start resets `LaunchTime`.

The reaper finds the `Project` key in any case. It reads `ExpiresAt` only
with the exact case, because the TTL guard does the same.

## Bootstrap the account

Do this procedure one time. It needs a human with the `playground-ops`
SSO profile.

1. Log in to the bootstrap profile:

   ```sh
   aws sso login --profile playground-ops
   ```

2. Make sure that no old security group has the name `fastmem-bench-ssh`
   in the default VPC:

   ```sh
   AWS_PROFILE=playground-ops aws ec2 describe-security-groups --region us-west-2 \
     --filters Name=group-name,Values=fastmem-bench-ssh --query 'SecurityGroups[].[GroupId,VpcId]'
   ```

3. If the command shows a group in the default VPC, and no instance uses
   it, delete it:

   ```sh
   AWS_PROFILE=playground-ops aws ec2 delete-security-group --region us-west-2 --group-id <id>
   ```

4. Apply the IAM stack. It creates the user, the policy, the access key,
   and the reaper.

   ```sh
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam init
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam apply
   ```

5. Write the credentials profile:

   ```sh
   infra/iam/write-credentials.sh
   ```

6. Wait 10 seconds. A new access key is not valid immediately.

7. Make sure that the profile works:

   ```sh
   AWS_PROFILE=fastmem-bench aws sts get-caller-identity
   ```

   The `Arn` field must be `arn:aws:iam::396684171460:user/fastmem-bench`.

8. Do the procedure "Make sure that the reaper runs".

9. Optional: check the policies with IAM Access Analyzer. Findings of type
   `ERROR` or `SECURITY_WARNING` need a fix.

   ```sh
   arn=$(tofu -chdir=infra/iam output -raw policy_arn)
   version=$(AWS_PROFILE=playground-ops aws iam get-policy --policy-arn "$arn" \
     --query Policy.DefaultVersionId --output text)
   AWS_PROFILE=playground-ops aws iam get-policy-version --policy-arn "$arn" \
     --version-id "$version" --query PolicyVersion.Document >/tmp/bench-policy.json
   AWS_PROFILE=playground-ops aws accessanalyzer validate-policy --region us-west-2 \
     --policy-type IDENTITY_POLICY --policy-document file:///tmp/bench-policy.json
   AWS_PROFILE=playground-ops aws iam get-role-policy --role-name fastmem-bench-reaper \
     --policy-name fastmem-bench-reaper --query PolicyDocument >/tmp/reaper-policy.json
   AWS_PROFILE=playground-ops aws accessanalyzer validate-policy --region us-west-2 \
     --policy-type IDENTITY_POLICY --policy-document file:///tmp/reaper-policy.json
   ```

## Change the IAM stack

A change to `iam/` or to `modules/bench-iam/` needs a human.

1. If the change needs a new launch template, apply the base stack first.
   For example, the policy requires the `Project` tag on new network
   interfaces, and the launch template supplies it.

2. Examine the plan. Make sure that it does not replace
   `module.bench.aws_iam_access_key.bench`:

   ```sh
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam plan
   ```

3. Apply the stack:

   ```sh
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam apply
   ```

4. Do the procedure "Make sure that the policy refuses bad tags".

5. Do the procedure "Make sure that the reaper runs".

## Make sure that the policy refuses bad tags

The commands use `--dry-run`. EC2 checks the permissions and launches
nothing. `DryRunOperation` means "allowed". `UnauthorizedOperation` means
"refused".

1. Get the arm64 launch template:

   ```sh
   lt=$(tofu -chdir=infra/base output -json launch_template_ids | jq -r .arm64)
   ```

2. Send a request with canonical tags. The result must be
   `DryRunOperation`:

   ```sh
   AWS_PROFILE=fastmem-bench aws ec2 run-instances --region us-west-2 --dry-run \
     --instance-type c8g.large --launch-template "LaunchTemplateId=$lt,Version=\$Latest" \
     --tag-specifications \
     'ResourceType=instance,Tags=[{Key=Project,Value=fastmem-bench},{Key=ExpiresAt,Value=2030-01-01T00:00:00Z}]'
   ```

3. Send the same request with the key `PROJECT`. The result must be
   `UnauthorizedOperation`:

   ```sh
   AWS_PROFILE=fastmem-bench aws ec2 run-instances --region us-west-2 --dry-run \
     --instance-type c8g.large --launch-template "LaunchTemplateId=$lt,Version=\$Latest" \
     --tag-specifications \
     'ResourceType=instance,Tags=[{Key=PROJECT,Value=fastmem-bench},{Key=ExpiresAt,Value=2030-01-01T00:00:00Z}]'
   ```

## Make sure that the reaper runs

1. Wait 5 minutes after the apply.

2. Read the log:

   ```sh
   AWS_PROFILE=playground-ops aws logs tail /aws/lambda/fastmem-bench-reaper \
     --region us-west-2 --since 15m
   ```

3. Make sure that each run wrote one line with `"summary"` in it, and that
   `"errors"` is empty.

To start a run immediately, invoke the function:

```sh
AWS_PROFILE=playground-ops aws lambda invoke --region us-west-2 \
  --function-name fastmem-bench-reaper /dev/stdout
```

## Operate the reaper

The reaper writes one JSON line for each action and one `summary` line for
each run. Each action line has the resource ID, the reason, and the result.

If an action fails, the run ends with an error after all other actions. The
`Errors` metric of the function counts these runs. No alarm watches it.

To see the decisions of the reaper without a change to AWS, use a dry run:

1. In `iam/main.tf`, add `reaper_dry_run = true` to `module "bench"`.
2. Apply the IAM stack.
3. Read the log. In a dry run, EC2 checks each call and changes nothing.
   A result of `ok` means that the role has the permission.
4. Remove `reaper_dry_run` and apply the IAM stack again.

To change the maximum lifetime, set `reaper_max_lifetime_hours` in
`module "bench"` in `iam/main.tf`. Keep it above `fleet.max_ttl`. Then apply
the IAM stack.

## Apply the base stack

The bench profile applies this stack. A human or an agent can do it.

1. Apply the stack:

   ```sh
   AWS_PROFILE=fastmem-bench tofu -chdir=infra/base init
   AWS_PROFILE=fastmem-bench tofu -chdir=infra/base apply
   ```

2. Make sure that the outputs exist:

   ```sh
   tofu -chdir=infra/base output -json
   ```

The apply writes the SSH private key to `infra/base/bench.pem` with mode
`0600`. The harness reads these outputs:

| Output | Value |
|---|---|
| `launch_template_ids` | Map from architecture (`x86_64`, `arm64`) to launch template ID |
| `key_file` | Absolute path of `bench.pem` |
| `security_group_id` | ID of the SSH security group |

## Change the box image

The box configuration has two parts:

- `modules/bench-base/image.nix.tftpl` holds the fleet contract: the TTL
  guard, nix-ld, the benchmark sysctls, and `/etc/bench-image`.
- `base/image.nix` holds the fastmem packages. The template imports it.

1. Edit one of the two files.

2. Render the configuration:

   ```sh
   echo 'base64encode(module.bench.user_data)' | tofu -chdir=infra/base console \
     | tr -d '"' | base64 -d >/tmp/box.nix
   ```

3. Make sure that the file evaluates against the channel of the AMI.
   Do this for `x86_64-linux` and for `aarch64-linux`:

   ```sh
   nix eval --impure --raw \
     -I nixpkgs=https://releases.nixos.org/nixos/25.11/nixos-25.11.12484.b6018f87da91/nixexprs.tar.xz \
     --expr '(import <nixpkgs/nixos> { configuration = /tmp/box.nix; system = "x86_64-linux"; }).config.system.build.toplevel.drvPath'
   ```

4. If the change matters to the harness, increase `image_version` in
   `base/main.tf`. Set `image_version` in `bench.toml` to the same value.

5. Apply the base stack. The apply adds a new version to each launch
   template.

6. Terminate the boxes. Old boxes keep the old configuration.

   ```sh
   uv run bench down --all
   ```

## Change an AMI

1. Find the new NixOS AMIs. The publisher account is `427812963091`:

   ```sh
   AWS_PROFILE=fastmem-bench aws ec2 describe-images --region us-west-2 --owners 427812963091 \
     --filters 'Name=name,Values=nixos/25.11*' \
     --query 'sort_by(Images,&CreationDate)[-4:].[ImageId,Name,Architecture]' --output table
   ```

2. Set the IDs in `amis` in `base/main.tf`.

3. If the NixOS release changes, change these values to the new release:
   - `system.stateVersion` in `modules/bench-base/image.nix.tftpl`
   - the channel URL in the evaluation step of "Change the box image"
   - the comment above `amis` in `base/main.tf`

4. Do the procedure "Change the box image" from step 2.

## Change the instance allowlist

1. Edit `instance_families` in `iam/main.tf`.
2. Do the procedure "Change the IAM stack".

## Rotate the access key

1. Replace the key:

   ```sh
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam apply -replace=module.bench.aws_iam_access_key.bench
   ```

2. Write the credentials profile again:

   ```sh
   infra/iam/write-credentials.sh
   ```

## Tear down

1. Terminate all boxes:

   ```sh
   uv run bench down --all
   ```

2. Destroy the base stack:

   ```sh
   AWS_PROFILE=fastmem-bench tofu -chdir=infra/base destroy
   ```

3. Destroy the IAM stack. This step also removes the reaper, so do it last.

   ```sh
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam destroy
   ```

4. Remove the `[fastmem-bench]` section from `~/.aws/credentials`.

## Test the modules offline

The tofu tests use mock providers. They need no AWS credentials, and they
create no files. The reaper tests need no AWS SDK.

```sh
tofu -chdir=infra/modules/bench-iam init -backend=false
tofu -chdir=infra/modules/bench-iam test
tofu -chdir=infra/modules/bench-base init -backend=false
tofu -chdir=infra/modules/bench-base test
python3 -m unittest discover -s infra/modules/bench-iam/reaper -v
```

The `bench-iam` tests fail if the user policy is longer than 6,144
characters, the limit of a managed policy. If that occurs, split the policy
into two managed policies on the user.

## The TTL guard

The TTL guard is the fast path. The reaper is the guarantee. Refer to "The
lifetime guarantee".

Every box runs `bench-ttl-guard.timer` one time each minute. The service
gets an IMDSv2 token and reads the `ExpiresAt` instance tag from
`http://169.254.169.254/latest/meta-data/tags/instance/ExpiresAt`.

- If the tag is an RFC 3339 UTC time, the guard uses it.
- If the tag is absent or has a different format, the guard uses boot time
  plus 12 hours.
- If IMDS does not answer, the guard uses the last value that it read. If it
  has no value, it uses boot time plus 12 hours.
- If the current time is after the limit, the guard runs `poweroff`. The
  launch template sets shutdown behavior to `terminate`, so EC2 deletes the
  instance and its volume.

To examine the guard on a box, use these commands:

```sh
systemctl list-timers bench-ttl-guard.timer
journalctl -u bench-ttl-guard.service
```

## The IAM policy

`modules/bench-iam/policy.tf` has one comment for each statement. The
`Project` tag is the security boundary. The bench user can do these things:

- Describe and get all EC2 resources in `us-west-2`.
- Launch On-Demand instances from a project launch template. The request
  must tag the instance, the volume, and the network interface with
  `Project`, and the instance with `ExpiresAt`. A tag from the launch
  template also counts.
- Use only the instance types in the allowlist, and only default tenancy.
- Use the AMI, the security group, and the key pair of the launch template.
  The AMI must come from the NixOS publisher.
- Create gp3 volumes of 100 GiB or smaller, with at most 3000 IOPS and
  125 MiB/s. These are the gp3 baseline values, which cost nothing extra.
- Tag project resources with these keys only: `Project`, `ManagedBy`,
  `Name`, `Target`, `ExpiresAt`, `Owner`. It cannot change the `Project`
  value.
- Remove tags from project resources, except `Project` and `ExpiresAt`.
- Terminate project instances. It cannot stop or start them.
- Create, change, and delete the security group, the key pair, and the
  launch templates of `infra/base`. It can create security groups only in the
  default VPC.

The policy grants no IAM, S3, Lambda, or other service. It denies all
actions outside `us-west-2`. The user has no `iam:PassRole`, so an instance
cannot get an instance profile. The user cannot change the reaper.

The policy cannot control the `user_data`, the shutdown behavior, or the
metadata options of a launch. The reaper covers these gaps.

The policy is a customer managed policy. IAM limits the inline policies of a
user to 2,048 characters in total, and this policy is larger.

## The reaper role

The reaper has its own IAM role. Its policy allows these actions only:

- `ec2:DescribeInstances`, `ec2:DescribeVolumes`, and
  `ec2:DescribeNetworkInterfaces` on all resources.
- `ec2:TerminateInstances` and `ec2:ModifyInstanceAttribute` on project
  instances.
- `ec2:DeleteVolume` and `ec2:DeleteNetworkInterface` on project volumes and
  network interfaces.
- `ec2:CreateTags` on project network interfaces, with the `OrphanSeenAt`
  key only.
- `logs:CreateLogStream` and `logs:PutLogEvents` on the reaper log group.

The log group keeps logs for 30 days (`reaper_log_retention_days`).

## Fault isolation

- If an EC2 call fails with `UnauthorizedOperation` and an encoded message,
  decode the message with the bootstrap profile:

  ```sh
  AWS_PROFILE=playground-ops aws sts decode-authorization-message \
    --encoded-message <message> --query DecodedMessage --output text | jq .
  ```

- If a box does not become ready, read its console output. Then terminate
  the box.

  ```sh
  AWS_PROFILE=fastmem-bench aws ec2 get-console-output --region us-west-2 \
    --instance-id <id> --latest --output text
  ```

- If a box stopped before its `ExpiresAt`, search the reaper log for its
  instance ID. The action line gives the reason.

- If the base apply fails with `InvalidGroup.Duplicate`, do steps 2 and 3 of
  "Bootstrap the account".

## Copy into another project

1. Copy `infra/` and `bench/ec2bench/` into the other repository.
2. Write its `bench.toml`. Set `name` and `profile` in `[project]`.
3. Set `project`, `region`, and `account_id` in `locals` of both root
   stacks.
4. If the project uses other instance families, edit `instance_families`
   in `iam/main.tf`.
5. Replace `base/image.nix` with the NixOS module of the project.
6. Do the procedures "Bootstrap the account" and "Apply the base stack".
