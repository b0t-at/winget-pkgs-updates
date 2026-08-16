import os
import glob
import json
import yaml

# Paths
base_dir = os.path.dirname(os.path.abspath(__file__))
monitored_file = os.path.join(base_dir, "../github-releases-monitored.yml")
workflows_dir = os.path.join(base_dir, "../.github/workflows")
template_file = os.path.join(base_dir, "../.github/workflows-templates/github-releases.yml")

# Constants
workflow_prefix = "update-github-packages-"
workflow_suffix = ".yml"

# Step 1: Read the monitored file
with open(monitored_file, "r") as file:
    monitored_data = yaml.safe_load(file)

# Step 3: Delete existing workflow files
existing_workflows = glob.glob(os.path.join(workflows_dir, f"{workflow_prefix}*{workflow_suffix}"))
for workflow in existing_workflows:
    os.remove(workflow)

# Step 4: Create new workflow files
with open(template_file, "r") as file:
    template_content = file.read()


def transform_matrix_item(item):
    transformed_item = {}
    for key, value in item.items():
        output_key = "With" if key == "with" else key
        transformed_item[output_key] = value
    return transformed_item


def render_packages_json(chunk):
    transformed_chunk = [transform_matrix_item(item) for item in chunk]
    item_lines = ",\n".join(
        f"              {json.dumps(item, ensure_ascii=False)}"
        for item in transformed_chunk
    )
    return f"            [\n{item_lines}\n            ]"


DISPATCH_EXPRESSION = "${{ github.event_name == 'workflow_dispatch' && inputs.submission_repository || 'microsoft/winget-pkgs' }}"

# Present verbatim in the template, so it doubles as the anchor that the
# test-fork dispatch inputs are appended to.
DISPATCH_BASE_INPUTS = """on:
  workflow_dispatch:
    inputs:
      batch_size:
        description: "Packages to process in this run (random pick from everything needing an update)"
        required: false
        default: 30
        type: number
"""

DISPATCH_INPUTS = DISPATCH_BASE_INPUTS + """      submission_repository:
        description: "Pull request target; test fork requires acknowledgement"
        required: true
        default: microsoft/winget-pkgs
        type: choice
        options:
          - microsoft/winget-pkgs
          - damn-good-b0t/winget-pkgs
      allow_test_fork_submission:
        description: "Acknowledge that this dispatch may create PRs only in damn-good-b0t/winget-pkgs"
        required: true
        default: false
        type: boolean
"""

CHECK_SUBMIT_RUN_PINNED = """        run: |
          if ("$env:VARS_SUBMIT_PR" -ne "true") {
            Write-Host "::warning::SUBMIT_PR is not set to 'true', skipping PR submission"
            "skip=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
          } else {
            Write-Host "SUBMIT_PR is enabled, proceeding with PR submission"
            "skip=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
          }
        env:
          VARS_SUBMIT_PR: ${{ vars.SUBMIT_PR }}
"""

CHECK_SUBMIT_RUN_DISPATCH = """        run: |
          $targetRepository = "$env:WINGET_PKGS_SUBMISSION_REPOSITORY"
          $isTestForkTarget = $targetRepository -ceq 'damn-good-b0t/winget-pkgs'
          if ($isTestForkTarget -and "$env:WINGET_PKGS_ALLOW_TEST_FORK_SUBMISSION" -cne 'true') {
            throw 'Test-fork submission requires the allow_test_fork_submission workflow_dispatch acknowledgement.'
          }
          if ($targetRepository -notin @('microsoft/winget-pkgs', 'damn-good-b0t/winget-pkgs')) {
            throw "Unsupported submission repository '$targetRepository'."
          }
          if ("$env:VARS_SUBMIT_PR" -ne "true") {
            Write-Host "::warning::SUBMIT_PR is not set to 'true', skipping PR submission"
            "skip=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
          } else {
            if ($isTestForkTarget) {
              Write-Host 'Test-fork submission is explicitly acknowledged; any PR will be created only in damn-good-b0t/winget-pkgs.'
            }
            Write-Host "SUBMIT_PR is enabled, proceeding with PR submission"
            "skip=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
          }
        env:
          VARS_SUBMIT_PR: ${{ vars.SUBMIT_PR }}
          WINGET_PKGS_SUBMISSION_REPOSITORY: DISPATCH_EXPRESSION
          WINGET_PKGS_ALLOW_TEST_FORK_SUBMISSION: ${{ github.event_name == 'workflow_dispatch' && inputs.allow_test_fork_submission || 'false' }}
""".replace("DISPATCH_EXPRESSION", DISPATCH_EXPRESSION)


def replace_exactly_once(content, old, new, description, workflow_file):
    occurrences = content.count(old)
    if occurrences != 1:
        raise SystemExit(
            f"Expected exactly one occurrence of {description} while generating "
            f"{workflow_file}, found {occurrences}. Template drift detected."
        )
    return content.replace(old, new)


def apply_test_fork_dispatch(content, workflow_file):
    """Wire the designated workflow for acknowledged test-fork submissions.

    Exactly one generated workflow (the last chunk) may target the
    damn-good-b0t/winget-pkgs test fork via workflow_dispatch inputs; all
    other workflows stay pinned to microsoft/winget-pkgs.
    """
    content = replace_exactly_once(
        content,
        DISPATCH_BASE_INPUTS,
        DISPATCH_INPUTS,
        "the workflow_dispatch trigger",
        workflow_file,
    )
    content = replace_exactly_once(
        content,
        "          GHURLs: ${{ matrix.url }}",
        f"          WINGET_PKGS_SUBMISSION_REPOSITORY: {DISPATCH_EXPRESSION}\n"
        "          GHURLs: ${{ matrix.url }}",
        "the Generate manifest matrix env block",
        workflow_file,
    )
    content = replace_exactly_once(
        content,
        CHECK_SUBMIT_RUN_PINNED,
        CHECK_SUBMIT_RUN_DISPATCH,
        "the Check SUBMIT_PR step",
        workflow_file,
    )
    content = replace_exactly_once(
        content,
        "          WINGET_PKGS_SUBMISSION_REPOSITORY: microsoft/winget-pkgs\n",
        f"          WINGET_PKGS_SUBMISSION_REPOSITORY: {DISPATCH_EXPRESSION}\n",
        "the pinned Submit PR submission repository",
        workflow_file,
    )
    return content


def create_workflow_file(chunk, workflows_dir, workflow_prefix, workflow_suffix, template_content, cron_minute, is_dispatch_target):
    # min/max keeps the slug order-independent of the monitored list.
    start_char = min(item['id'][0].lower() for item in chunk)
    end_char = max(item['id'][0].lower() for item in chunk)
    range_slug = f"{start_char}-{end_char}"

    # Create a workflow file name with the starting and ending characters
    workflow_file = os.path.join(
        workflows_dir, 
        f"{workflow_prefix}{range_slug}{workflow_suffix}"
    )
    
    # Replace the placeholder inside the MONITORED_PACKAGES block scalar with
    # the package list as JSON (consumed by Select-PackagesNeedingUpdate.ps1).
    updated_content = template_content.replace(
        "            # Orchestrator will insert Packages JSON here",
        render_packages_json(chunk)
    )
    # Update filename
    updated_content = updated_content.replace(
        "name: GH Packages",
        f"name: GH Packages {start_char.upper()}-{end_char.upper()}"
    )
    # Stagger the schedule so concurrent workflows do not hammer the shared
    # GitHub API quota at the same minute.
    updated_content = updated_content.replace(
        'cron: "3 0/4 * * *"',
        f'cron: "{cron_minute} 0/4 * * *"'
    )
    # Do not overlap runs of the same workflow.
    updated_content = replace_exactly_once(
        updated_content,
        "permissions:\n  contents: read\n\njobs:",
        "permissions:\n  contents: read\n\n"
        "# Do not overlap runs of this workflow.\n"
        "concurrency:\n"
        f"  group: {workflow_prefix}{range_slug}\n"
        "  cancel-in-progress: false\n\njobs:",
        "the permissions block",
        workflow_file,
    )
    if is_dispatch_target:
        updated_content = apply_test_fork_dispatch(updated_content, workflow_file)
    # Write the new workflow file
    with open(workflow_file, "w") as file:
        file.write(updated_content)

chunks = [monitored_data]

# The check-updates precheck keeps the runtime matrix small (and caps any
# fail-open fallback at GitHub's 256-job matrix limit), so a single workflow
# covers all monitored packages. The single chunk is also the designated
# workflow_dispatch target for acknowledged test-fork runs.
minute_step = 60 // max(1, len(chunks))
for index, chunk in enumerate(chunks):
    cron_minute = (3 + index * minute_step) % 60
    is_dispatch_target = index == len(chunks) - 1
    create_workflow_file(chunk, workflows_dir, workflow_prefix, workflow_suffix, template_content, cron_minute, is_dispatch_target)

files = len(chunks)
print(f"Generated {files} workflow files in {workflows_dir}.")