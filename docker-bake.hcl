variable "TAG" {
  default = "slim"
}

# === Version Pins (single source of truth) ===
variable "COMFYUI_VERSION" {
  default = "v0.28.3"
}

# Regular image (cu128)
variable "TORCH_VERSION" {
  default = "2.10.0+cu128"
}
variable "TORCHVISION_VERSION" {
  default = "0.25.0+cu128"
}
variable "TORCHAUDIO_VERSION" {
  default = "2.10.0+cu128"
}

# 5090 / Blackwell image (cu130)
variable "TORCH_VERSION_5090" {
  default = "2.10.0+cu130"
}
variable "TORCHVISION_VERSION_5090" {
  default = "0.25.0+cu130"
}
variable "TORCHAUDIO_VERSION_5090" {
  default = "2.10.0+cu130"
}

variable "FILEBROWSER_VERSION" {
  default = "v2.59.0"
}
variable "FILEBROWSER_SHA256" {
  default = "8cd8c3baecb086028111b912f252a6e3169737fa764b5c510139e81f9da87799"
}

group "default" {
  targets = ["regular", "cuda13"]
}

# Common settings for all targets (defaults to regular CUDA 12.8 / cu128)
target "common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    COMFYUI_VERSION     = COMFYUI_VERSION
    TORCH_VERSION       = TORCH_VERSION
    TORCHVISION_VERSION = TORCHVISION_VERSION
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION
    FILEBROWSER_VERSION = FILEBROWSER_VERSION
    FILEBROWSER_SHA256  = FILEBROWSER_SHA256
    CUDA_VERSION_DASH   = "12-8"
    TORCH_INDEX_SUFFIX  = "cu128"
  }
}

# Regular ComfyUI image (CUDA 12.8 — default)
target "regular" {
  inherits = ["common"]
  tags = [
    "ghcr.io/gremlation/runpod-comfyui:${TAG}-cuda12.8",
    "ghcr.io/gremlation/runpod-comfyui:cuda12.8",
    "ghcr.io/gremlation/runpod-comfyui:latest",
  ]
}

# CUDA 13.0 image (Blackwell / RTX 5090+)
target "cuda13" {
  inherits = ["common"]
  tags = [
    "ghcr.io/gremlation/runpod-comfyui:${TAG}-cuda13.0",
    "ghcr.io/gremlation/runpod-comfyui:cuda13.0",
  ]
  args = {
    TORCH_VERSION       = TORCH_VERSION_5090
    TORCHVISION_VERSION = TORCHVISION_VERSION_5090
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION_5090
    CUDA_VERSION_DASH   = "13-0"
    TORCH_INDEX_SUFFIX  = "cu130"
  }
}

# Dev targets for local testing
target "dev" {
  inherits = ["common"]
  tags = ["ghcr.io/gremlation/runpod-comfyui:dev"]
  output = ["type=docker"]
}

target "dev-cuda13" {
  inherits = ["common"]
  tags = ["ghcr.io/gremlation/runpod-comfyui:dev-cuda13.0"]
  output = ["type=docker"]
  args = {
    TORCH_VERSION       = TORCH_VERSION_5090
    TORCHVISION_VERSION = TORCHVISION_VERSION_5090
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION_5090
    CUDA_VERSION_DASH   = "13-0"
    TORCH_INDEX_SUFFIX  = "cu130"
  }
}
