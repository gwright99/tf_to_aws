# Introduction
Following Kyler Middleton's tutorial ["An Intro to GitHub Actions + Terraform + AWS"](https://medium.com/swlh/lets-do-devops-github-actions-terraform-aws-77ef6078e4f2). Modifying flow as I will be standing up infrastructure in the Seqera Dev account, so this means:
1. I don't need to create a new IAM user.
2. I must reuse and existing S3 Bucket for storing state (since I can't create a new one).


## Boostrapping the necessary `backend` state-storage infrastructure.
My Terraform state needs to be somewhere internet-accessible (_i.e. not stored locally on my computer_) in order for Github Actions to interact with it. The general approach seems to be to:

1. Use an **S3 Bucket** for storage.
2. Use a **DynamoDB table** for state-change conflict management (i.e. filelock).
3. **Github Secrets** for credential storage.

Unfortunately, the setup of the Seqera infrastructure is problematic on three of these fronts:

1. I do not have access to create Github Secrets in the Seqera Github repo. This means I need to use my own repository rather than our tooling repository.
2. We use `gsts` to get temporary AWS credentials based on my Google identity. Longer-lived keys must be given to Github Secrets (to be used by GHA). This means I need to use the `TowerDevelopmentUser` keyset rather than `gsts`.
3. Due to the Development environment forbidding the creation of new Buckets, I will need to reuse one I created previously. 


### Decision 1: Deviate from standard project initialization
The standard way of initializing a project like this appears to be "_create your backend's S3 and DynamoDB resources with TF before pushing to the remote backend_" (see [example1]((https://medium.com/swlh/lets-do-devops-bootstrap-aws-to-your-terraform-ci-cd-azure-devops-github-actions-etc-b3cc5a636dce)) and [example2]((https://rderik.com/blog/how-to-set-up-a-new-terraform-project-using-s3-backend-and-dynamodb-locking/))). 

Given the constraints stated above, I can't do this so - as a result - I'll just manually create and hardcode the DynamoDB table too, and use an S3 backend configuration immediatley.


### Decision 2: Forego Terragrunt
I decided not to use Terragrunt because I felt it added additional dependencies and complexity for minimal gains. As per [Terragrunt? Probably not](https://www.youtube.com/watch?v=AblXItaUdCg), the suggestion was that Terragrunt was primarily created for Terraform problems of a certain (past) time and did not make as much sense to include in new projects.

**TO DO:** Return in future to evaluate if additional complexity in project warrants the inclusion of a Terragrunt layer.


### Problem 1: Setting up Credentials to allow local machine to push state to S3
My local machine is configured with several profiles in `~/.aws/credentials`. The default profile points to my personal account, whereas I set an environment variable `AWS_DEFAULT_PROFILE=sts` to force calls to AWS to use the temporary credentials generated by my `gsts` session.

The Role I needed to get to the `backend s3` block had a long-lived access key and secret key, and had to assume a Role. I tried several configurations with no luck, including:

- [TF_VAR](https://stackoverflow.com/questions/55052153/how-to-configure-environment-variables-in-hashicorp-terraform) (e.g. `export TF_VAR_access_key=xxxx && TF_VAR_secret_key=xxxxx && export TF_VAR_role_arn=arn:aws:iam::128997144437:role/xxxxx`)
- [backend-config](https://developer.hashicorp.com/terraform/language/settings/backends/s3#credentials-and-shared-configuration) (e.g. `terraform init -backend-config="access_key=${TF_VAR_access_key}" -backend-config="secret_key=${TF_VAR_secret_key}" -backend-config="role_arn=${TF_VAR_role_arn}"`)

What eventually worked was three-pronged:

1. Hardcode the User keys as environment variables (e.g. `export AWS_ACCESS_KEY_ID=xxxx && export AWS_SECRET_ACCESS_KEY=xxxx`)
2. Unsetting any other `AWS_*` variable specifying default profiles.
3. Adding `role_arn` to the `backend s3` configuration.

** NOTE! **
- When `terraform init` is first run, it generates a local `.terraform` folder which includes a `terraform.tfstate` file, but there are no equivalents on the S3 bucket side. The S3 bucket only received files after running a `terraform apply` command! I found this quite confusing, although recall seeing a comment in the TF documenting mentioning this behaviour. Beware!


### Problem 2: Setting up Credentials to allow Terraform to be able to create resources in AWS
The `TowerDevelopmentUser` IAM Role I was trying to use has limited AWS Permissions. I encountered this quickly during testing:

- I could successfully create non-AWS resources like `resource "tls_private_key"` and push this state to the S3-based state file.
- I failed to create a new AWS Security Group, because it relied upon the results of `data "aws_vpc"`, which in turn made several API calls to AWS. One of those calls, `DescribeVpcAttribute` was not allowed, which caused the failure.

Given previous successful Terraform projects, I knew my `gsts` credentials could create this Security Group. To test this I:

1. Unset the keys (i.e `unset AWS_ACCESS_KEY_ID && unset AWS_SECRET_ACCESS_KEY`).
2. Reset the gsts profile (i.e. `export AWS_DEFAULT_PROFILE=sts`).

This ended up failing due to `error configuring S3 Backend: IAM Role (arn:aws:iam::128997144437:role/TowerDevelopmentRole) cannot be assumed.` I needed to re-add the hardcoded keys so that we could talk to the state file in S3.

Finally, I was able to get `terraform apply` to work by adding the `profile` key to **provider "aws"`:

    ```terraform
    provider "aws" {
        # shared_credentials_files        = ["~/.aws/credentials"]
        region                          = var.region
        profile                         = "sts" # var.profile
        # assume_role {
        #   role_arn                      = "arn:aws:iam::128997144437:role/TowerDevelopmentRole"
        #   session_name                  = "graham_tf_session"
    # }
    ```

### Problem 3: How to credentialize the Terraform which will be run by Github Actions?
The solution to Problem 2 will not work when Terraform is executed by GHA because the GH runner will not have my gsts credentials. Another solution needs to be found.

I knew Adianny had been successfully integrating GHAs with our AWS Development environment, so I reached out to him to see how we had done it. I figured he either used a more muscular role with long-lived keys, or he was using some sort of technique to assume temporary keys of a strong Role. A bit of Googling later, I found this gem of an article: [https://benoitboure.com/securely-access-your-aws-resources-from-github-actions](https://benoitboure.com/securely-access-your-aws-resources-from-github-actions)


## Success! But there are problems ...
After configuring OIDC access, I could successfully deploy from GHA to AWS. But now I had a new problem ... How would I delete the infrastructure created by the GHA?

### `AWS_PROFILE` rather than `AWS_DEFAULT_PROFILE`
I clone the repo locally and tried to run `terraform plan` to ensure my local instance could see the same state as what was created by the GHA. 

I was receiving confusing 403 HTTP responses, which didn't make sense given that I was using the powerful `gsts` Role. I set `TF_LOG=TRACE` and ran the init process again and this time happened to notice that the wrong Account (personal) was being identified rather than the role I thought I was using.

**CAVEAT!**
- Whereas I would normally set `AWS_DEFAULT_PROFILE=sts` to force the AWS CLI to use the gsts Role, it appears that Terraform expects `AWS_PROFILE`. My local instance was able to destroy GHA-created objects once I used:

    ```bash
    export AWS_PROFILE=sts
    terraform destroy --auto-approve
    ```