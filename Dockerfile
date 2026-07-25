# ============================================================================
# Stage 1: Builder - Download pinned sources and install all Python packages
# ============================================================================
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# ---- Version pins (set in docker-bake.hcl) ----
ARG COMFYUI_VERSION
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCHAUDIO_VERSION

# ---- CUDA variant (set in docker-bake.hcl per target) ----
ARG CUDA_VERSION_DASH=12-8
ARG TORCH_INDEX_SUFFIX=cu128

# Install minimal dependencies needed for building
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    wget \
    curl \
    git \
    ca-certificates \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    build-essential \
    && wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i cuda-keyring_1.1-1_all.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-minimal-build-${CUDA_VERSION_DASH} libcusparse-dev-${CUDA_VERSION_DASH} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm cuda-keyring_1.1-1_all.deb \
    && rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED

# Install pip and pip-tools for lockfile generation
RUN curl -sS https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
    python3.12 get-pip.py && \
    python3.12 -m pip install --no-cache-dir pip-tools && \
    rm get-pip.py

# Set CUDA environment for building
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64

# Download pinned ComfyUI source
WORKDIR /tmp/build
RUN curl -fSL "https://github.com/comfyanonymous/ComfyUI/archive/refs/tags/${COMFYUI_VERSION}.tar.gz" -o comfyui.tar.gz && \
    mkdir -p ComfyUI && tar xzf comfyui.tar.gz --strip-components=1 -C ComfyUI && rm comfyui.tar.gz

# Install pinned torch stack and comfy-cli so custom node installs can compile
WORKDIR /tmp/build
RUN TORCH_INDEX_URL="https://download.pytorch.org/whl/${TORCH_INDEX_SUFFIX}" && \
    python3.12 -m pip install --no-cache-dir --upgrade pip && \
    python3.12 -m pip install --no-cache-dir \
    --index-url https://pypi.org/simple \
    --extra-index-url "${TORCH_INDEX_URL}" \
    "torch==${TORCH_VERSION}" \
    "torchvision==${TORCHVISION_VERSION}" \
    "torchaudio==${TORCHAUDIO_VERSION}" \
    -r ComfyUI/requirements.txt \
    comfy-cli && \
    python3.12 -c 'import torch; print(torch.__version__)'

# Install baked custom nodes from the registry-first / git-fallback list
COPY custom_nodes.json /tmp/build/custom_nodes.json
COPY scripts/install_nodes.py /tmp/build/install_nodes.py
RUN python3.12 /tmp/build/install_nodes.py /tmp/build/custom_nodes.json /tmp/build/ComfyUI

# Generate lock file from all requirements (including torch pins and node deps), then install with hash verification.
# Some custom nodes declare git+ dependencies (e.g. was-ns -> cstr) that pip-tools
# cannot hash. Install those separately and exclude them from the lockfile.
RUN cat /tmp/build/ComfyUI/requirements.txt > /tmp/build/requirements.in && printf '\n' >> /tmp/build/requirements.in && \
    for node_dir in /tmp/build/ComfyUI/custom_nodes/*/; do \
        if [ -f "$node_dir/requirements.txt" ]; then \
            cat "$node_dir/requirements.txt" >> /tmp/build/requirements.in && printf '\n' >> /tmp/build/requirements.in; \
        fi; \
    done && \
    echo "GitPython" >> /tmp/build/requirements.in && \
    echo "opencv-python" >> /tmp/build/requirements.in && \
    echo "pillow>=12.1.1" >> /tmp/build/requirements.in && \
    sed -i -E '/^[[:space:]]*(torch|torchvision|torchaudio)([[:space:]]|[\[<>=!~;#]|$)/d' /tmp/build/requirements.in && \
    echo "torch==${TORCH_VERSION}" >> /tmp/build/requirements.in && \
    echo "torchvision==${TORCHVISION_VERSION}" >> /tmp/build/requirements.in && \
    echo "torchaudio==${TORCHAUDIO_VERSION}" >> /tmp/build/requirements.in && \
    grep -E '^git\+https?://' /tmp/build/requirements.in > /tmp/build/git-requirements.txt || true && \
    sed -i -E '/^[[:space:]]*git\+https?:\/\//d' /tmp/build/requirements.in && \
    if [ -s /tmp/build/git-requirements.txt ]; then \
        echo "Installing git dependencies:" && cat /tmp/build/git-requirements.txt && \
        python3.12 -m pip install --no-cache-dir -r /tmp/build/git-requirements.txt; \
    fi && \
    TORCH_INDEX_URL="https://download.pytorch.org/whl/${TORCH_INDEX_SUFFIX}" && \
    PIP_INDEX_URL=https://pypi.org/simple \
    PIP_EXTRA_INDEX_URL="${TORCH_INDEX_URL}" \
    pip-compile --generate-hashes --output-file=/tmp/build/requirements.lock --strip-extras --allow-unsafe /tmp/build/requirements.in && \
    python3.12 -m pip install --no-cache-dir --ignore-installed --require-hashes \
    --index-url https://pypi.org/simple \
    --extra-index-url "${TORCH_INDEX_URL}" \
    -r /tmp/build/requirements.lock && \
    TORCH_VERSION="${TORCH_VERSION}" TORCHVISION_VERSION="${TORCHVISION_VERSION}" TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION}" \
    python3.12 -c 'import importlib.metadata as m, os, sys; expected = {"torch": os.environ["TORCH_VERSION"], "torchvision": os.environ["TORCHVISION_VERSION"], "torchaudio": os.environ["TORCHAUDIO_VERSION"]}; mismatches = [f"{pkg}: expected {version}, got {m.version(pkg)}" for pkg, version in expected.items() if m.version(pkg) != version]; sys.exit("\n".join(mismatches) if mismatches else 0)' && \
    python3.12 -m pip uninstall -y comfy-cli

# Init git repos with upstream remotes so ComfyUI-Manager can detect versions
RUN cd /tmp/build/ComfyUI && \
    git init && git add -A && git -c user.name=- -c user.email=- commit -q -m "ComfyUI ${COMFYUI_VERSION}" && git tag "${COMFYUI_VERSION}" && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI.git && \
    for node_dir in /tmp/build/ComfyUI/custom_nodes/*/; do \
        [ -d "${node_dir}/.git" ] && continue; \
        cd "${node_dir}" && \
        git init && git add -A && git -c user.name=- -c user.email=- commit -q -m "baked node" || true; \
    done

# Bake ComfyUI + custom nodes into the runtime location
RUN cp -r /tmp/build/ComfyUI /opt/ComfyUI

# ============================================================================
# Stage 2: Runtime - Clean image with pre-installed packages
# ============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV IMAGEIO_FFMPEG_EXE=/usr/bin/ffmpeg

# ---- CUDA variant (re-declared for runtime stage) ----
ARG CUDA_VERSION_DASH=12-8
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCHAUDIO_VERSION

# ---- FileBrowser version pin (set in docker-bake.hcl) ----
ARG FILEBROWSER_VERSION
ARG FILEBROWSER_SHA256

# Keep runtime pip installs aligned with the baked CUDA-specific PyTorch stack.
RUN printf "torch==%s\ntorchvision==%s\ntorchaudio==%s\n" \
    "$TORCH_VERSION" "$TORCHVISION_VERSION" "$TORCHAUDIO_VERSION" \
    > /opt/comfyui-runtime-constraints.txt

# Update and install runtime dependencies, CUDA, and common tools
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    git \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    build-essential \
    libssl-dev \
    wget \
    gnupg \
    xz-utils \
    openssh-client \
    openssh-server \
    nano \
    curl \
    htop \
    tmux \
    ca-certificates \
    less \
    net-tools \
    iputils-ping \
    procps \
    openssl \
    ffmpeg \
    && wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i cuda-keyring_1.1-1_all.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-minimal-build-${CUDA_VERSION_DASH} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm cuda-keyring_1.1-1_all.deb \
    && rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED

# Copy Python packages and executables from builder stage
COPY --from=builder /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy baked ComfyUI + custom nodes from builder stage
COPY --from=builder /opt/ComfyUI /opt/ComfyUI

# Copy model fallback config
COPY extra_model_paths.yaml /opt/ComfyUI/extra_model_paths.yaml

# Install FileBrowser (pinned version with checksum)
RUN curl -fSL "https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz" -o /tmp/fb.tar.gz && \
    echo "${FILEBROWSER_SHA256}  /tmp/fb.tar.gz" | sha256sum -c - && \
    tar xzf /tmp/fb.tar.gz -C /usr/local/bin filebrowser && \
    rm /tmp/fb.tar.gz

# Set CUDA environment variables
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64

# Allow container to start on hosts with older CUDA 12.x drivers
ENV NVIDIA_REQUIRE_CUDA=""
ENV NVIDIA_DISABLE_REQUIRE=true
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all

# Configure SSH for root login
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    mkdir -p /run/sshd && \
    rm -f /etc/ssh/ssh_host_*

# Create workspace directory
RUN mkdir -p /workspace/runpod-slim
WORKDIR /workspace/runpod-slim

# Expose ports (ComfyUI, SSH, FileBrowser)
EXPOSE 8188 22 8080

# Copy start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Set Python 3.12 as default and bake a venv on container disk for ComfyUI
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 && \
    update-alternatives --set python3 /usr/bin/python3.12 && \
    python3.12 -m venv --system-site-packages /opt/ComfyUI/.venv

ENTRYPOINT ["/start.sh"]
