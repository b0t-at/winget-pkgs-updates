import os
import glob
import yaml
from collections import defaultdict

# Paths
base_dir = os.path.dirname(os.path.abspath(__file__))
monitored_file = os.path.join(base_dir, "../github-releases-monitored.yml")
workflows_dir = os.path.join(base_dir, "../.github/workflows")
template_file = os.path.join(base_dir, "../.github/workflows-templates/github-releases.yml")

# Constants
batch_size = 250
workflow_prefix = "update-github-packages-"
workflow_suffix = ".yml"

# Step 1: Read the monitored file
with open(monitored_file, "r") as file:
    monitored_data = yaml.safe_load(file)

# Step 2: Split the objects into batches of 250
batches_dict = defaultdict(list)
for item in monitored_data:
    first_char = item['id'][0].lower()  # Group by the first character of 'id'
    batches_dict[first_char].append(item)

batches = list(batches_dict.values())

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


def render_include_section(chunk):
    transformed_chunk = [transform_matrix_item(item) for item in chunk]
    chunk_yaml = yaml.safe_dump(
        transformed_chunk,
        sort_keys=False,
        default_flow_style=False,
        allow_unicode=True,
        width=100000,
    ).rstrip()
    return "\n".join(f"          {line}" for line in chunk_yaml.splitlines())

def create_workflow_file(chunk, workflows_dir, workflow_prefix, workflow_suffix, template_content):
    start_char = chunk[0]['id'][0].lower()
    end_char = chunk[-1]['id'][0].lower()
    
    # Create a workflow file name with the starting and ending characters
    workflow_file = os.path.join(
        workflows_dir, 
        f"{workflow_prefix}{start_char}-{end_char}{workflow_suffix}"
    )
    
    # Prepare the include section as a YAML string
    include_section = render_include_section(chunk)
    
    # Replace the placeholder with the include section
    updated_content = template_content.replace(
        "    # Orchestrator will insert Packages here",
        include_section
    )
    # Update filename
    updated_content = updated_content.replace(
        "name: GH Packages",
        f"name: GH Packages {start_char.upper()}-{end_char.upper()}"
    )   
    # Write the new workflow file
    with open(workflow_file, "w") as file:
        file.write(updated_content)

chunk = []
files = 0
for batch_key, batch_items in batches_dict.items():
    if len(chunk)+len(batch_items) >= batch_size:
      create_workflow_file(chunk, workflows_dir, workflow_prefix, workflow_suffix, template_content)
      chunk = []
      files += 1
    for item in batch_items:
        chunk.append(item)

if chunk:
  create_workflow_file(chunk, workflows_dir, workflow_prefix, workflow_suffix, template_content)
  files += 1

print(f"Generated {files} workflow files in {workflows_dir}.")