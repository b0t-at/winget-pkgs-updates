import sys
import yaml

def read_packages(file_path):
    packages = []
    with open(file_path, 'r') as file:
        data = yaml.safe_load(file)
        jobs = data.get('jobs', {})
        for job in jobs.values():
            strategy = job.get('strategy', {})
            matrix = strategy.get('matrix', {})
            if not isinstance(matrix, dict):
                continue
            include = matrix.get('include', [])
            for item in include:
                packages.append(item.get('id') or item.get('PackageName'))
        return packages

if len(sys.argv) < 2:
    print("Please provide the file path as an argument.")
    sys.exit(1)

file_path = sys.argv[1]
packages = read_packages(file_path)
print(len(packages))