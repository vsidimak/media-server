import os

def generate_bootstrap_script(env_path, repo_url, install_dir="/opt/media-server-install"):
    with open(env_path, 'r') as f:
        env_lines = [line.strip() for line in f if line.strip() and not line.startswith('#')]

    env_block = "\n".join(env_lines)

    script = f"""#!/bin/bash
# Bootstrap script for EC2 media server setup

# Update and install dependencies
sudo apt update && sudo apt install -y git

# Clone repo
git clone {repo_url} {install_dir}
cd {install_dir}

# Create .env file
cat <<EOF > .env
{env_block}
EOF

chmod 600 .env

# Run install script
chmod +x install.sh
./install.sh
"""
    return script

# === USAGE ===
if __name__ == "__main__":
    REPO_URL = "https://github.com/vsidimak/media-server.git"
    ENV_PATH = ".env"  # your local env file

    bootstrap_script = generate_bootstrap_script(ENV_PATH, REPO_URL)
    with open("bootstrap.sh", "w") as f:
        f.write(bootstrap_script)

    print("✅ Generated 'bootstrap.sh'. Use this as EC2 user-data.")