#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/opt/ComfyUI"
NET_VOLUME_DIR="/workspace/runpod-slim"
NET_COMFY_DIR="${NET_VOLUME_DIR}/ComfyUI"
FAST_CACHE_DIR="/var/cache/comfyui/models"
FAST_TEMP_DIR="/var/cache/comfyui/temp"
FILEBROWSER_DB="${NET_VOLUME_DIR}/filebrowser.db"
PIP_CONSTRAINT_FILE="/opt/comfyui-runtime-constraints.txt"

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh

    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A -q
    fi

    # If PUBLIC_KEY is provided, use it
    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        # Generate random password if no public key
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    # Configure SSH to preserve environment variables
    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

    # Start SSH service
    /usr/sbin/sshd
}

# Export environment variables
export_env_vars() {
    echo "Exporting environment variables..."

    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"

    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true

    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"

    printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH|^PIP_CONSTRAINT=' | while read -r line; do
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)

        echo "$name=\"$value\"" >> "$ENV_FILE"
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done

    echo 'source /etc/rp_environment' >> ~/.bashrc
    echo 'source /etc/rp_environment' >> /etc/bash.bashrc

    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

# Start FileBrowser server
start_filebrowser() {
    if [ ! -f "$FILEBROWSER_DB" ]; then
        echo "Initializing FileBrowser..."
        filebrowser config init
        filebrowser config set --address 0.0.0.0
        filebrowser config set --port 8080
        filebrowser config set --root /workspace
        filebrowser config set --auth.method=json
        filebrowser users add admin "${FILEBROWSER_PASSWORD:-adminadmin12}" --perm.admin
    else
        echo "Using existing FileBrowser configuration..."
    fi

    echo "Starting FileBrowser on port 8080..."
    nohup filebrowser &> /filebrowser.log &
}

# Copy selected models from the network volume to the fast local cache
copy_fast_models() {
    FAST_MODELS_FILE="${NET_VOLUME_DIR}/fast-models.txt"

    mkdir -p "$FAST_CACHE_DIR"
    mkdir -p "$FAST_TEMP_DIR"

    # Ensure standard model subdirectories exist so downloads/saves work immediately
    for subdir in \
        checkpoints configs loras vae text_encoders clip diffusion_models unet \
        clip_vision style_models embeddings diffusers vae_approx controlnet \
        t2i_adapter gligen upscale_models latent_upscale_models hypernetworks \
        photomaker classifiers model_patches audio_encoders background_removal \
        frame_interpolation geometry_estimation optical_flow detection; do
        mkdir -p "${FAST_CACHE_DIR}/${subdir}"
    done

    if [ ! -f "$FAST_MODELS_FILE" ] || [ ! -s "$FAST_MODELS_FILE" ]; then
        echo "No fast-models.txt found; using network volume models directly."
        return
    fi

    echo "Copying fast models from network volume to local cache..."
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$line" ] && continue
        [[ "$line" =~ ^# ]] && continue

        src="${NET_COMFY_DIR}/models/${line}"
        dst="${FAST_CACHE_DIR}/${line}"

        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp -u "$src" "$dst"
            echo "  cached: $line"
        else
            echo "  WARNING: not found on network volume: $line"
        fi
    done < "$FAST_MODELS_FILE"
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

if [ -f "$PIP_CONSTRAINT_FILE" ]; then
    export PIP_CONSTRAINT="$PIP_CONSTRAINT_FILE"
    echo "Using runtime pip constraints from $PIP_CONSTRAINT_FILE"
fi

setup_ssh
export_env_vars
start_filebrowser

# Create default comfyui_args.txt if it doesn't exist
ARGS_FILE="${NET_VOLUME_DIR}/comfyui_args.txt"
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

copy_fast_models

# Start ComfyUI — keep container alive if it crashes so SSH/FileBrowser remain accessible
FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header --user-directory ${NET_COMFY_DIR}/user --models-directory ${FAST_CACHE_DIR} --output-directory ${NET_COMFY_DIR}/output --temp-directory ${FAST_TEMP_DIR} --input-directory ${NET_COMFY_DIR}/input --extra-model-paths-config ${COMFYUI_DIR}/extra_model_paths.yaml"
if [ -s "$ARGS_FILE" ]; then
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    if [ ! -z "$CUSTOM_ARGS" ]; then
        FIXED_ARGS="$FIXED_ARGS $CUSTOM_ARGS"
    fi
fi

echo "Starting ComfyUI with args: $FIXED_ARGS"
cd "$COMFYUI_DIR"
python main.py $FIXED_ARGS &
echo $! > /var/run/comfyui.pid

# Wait for the ComfyUI process; if it exits, keep the container alive for SSH/FileBrowser
wait $(cat /var/run/comfyui.pid) || true

echo "============================================="
echo "  ComfyUI exited — check the logs above."
echo "  SSH and FileBrowser are still available."
echo "  To restart after fixing:"
echo "    cd ${COMFYUI_DIR} && python main.py ${FIXED_ARGS}"
echo "============================================="

sleep infinity
