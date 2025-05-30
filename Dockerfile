# syntax=docker/dockerfile:1

ARG TARGET=base
ARG BASE_IMAGE=python:3.10-slim

FROM ${BASE_IMAGE} AS base

# Install curl and gpupg first so that we can use them to install google-cloud-cli.
# Any RUN apt-get install step needs to have apt-get update otherwise stale package
# list may occur when previous apt-get update step is cached. See here for more info:
# https://docs.docker.com/build/building/best-practices/#apt-get
RUN apt-get update && apt-get install -y curl gnupg

RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    apt-get update -y && \
    apt-get install -y apt-transport-https ca-certificates gcc g++ \
      git screen ca-certificates google-perftools google-cloud-cli

# Setup.
RUN mkdir -p /root
WORKDIR /root
# Introduce the minimum set of files for install.
COPY README.md README.md
COPY pyproject.toml pyproject.toml
RUN mkdir axlearn && touch axlearn/__init__.py
# Setup venv to suppress pip warnings.
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
# Install dependencies.
RUN pip install flit
RUN pip install --upgrade pip

################################################################################
# CI container spec.                                                           #
################################################################################

# Leverage multi-stage build for unit tests.
FROM base AS ci

# TODO(markblee): Remove gcp,vertexai_tensorboard from CI.
RUN pip install .[core,dev,grain,gcp,vertexai_tensorboard,open_api]
COPY . .

# Defaults to an empty string, i.e. run pytest against all files.
ARG PYTEST_FILES=''
# Defaults to empty string, i.e. do NOT skip precommit
ARG SKIP_PRECOMMIT=''
# `exit 1` fails the build.
RUN ./run_tests.sh $SKIP_PRECOMMIT "${PYTEST_FILES}"

################################################################################
# Bastion container spec.                                                      #
################################################################################

FROM base AS bastion

# TODO(markblee): Consider copying large directories separately, to cache more aggressively.
# TODO(markblee): Is there a way to skip the "production" deps?
COPY . /root/
RUN pip install .[core,gcp,vertexai_tensorboard]

################################################################################
# Dataflow container spec.                                                     #
################################################################################

FROM base AS dataflow

# Beam workers default to creating a new virtual environment on startup. Instead, we want them to
# pickup the venv setup above. An alternative is to install into the global environment.
ENV RUN_PYTHON_SDK_IN_DEFAULT_ENVIRONMENT=1
RUN pip install .[core,gcp,dataflow]
COPY . .

# Dataflow workers can't start properly if the entrypoint is not set
# See: https://cloud.google.com/dataflow/docs/guides/build-container-image#use_a_custom_base_image
COPY --from=apache/beam_python3.10_sdk:2.52.0 /opt/apache/beam /opt/apache/beam
ENTRYPOINT ["/opt/apache/beam/boot"]

################################################################################
# TPU container spec.                                                          #
################################################################################

FROM base AS tpu

ARG EXTRAS=

ENV PIP_FIND_LINKS=https://storage.googleapis.com/jax-releases/libtpu_releases.html
# Ensure we install the TPU version, even if building locally.
# Jax will fallback to CPU when run on a machine without TPU.
RUN pip install .[core,tpu]
RUN if [ -n "$EXTRAS" ]; then pip install .[$EXTRAS]; fi
COPY . .

################################################################################
# GPU container spec.                                                          #
################################################################################

FROM base AS gpu

# TODO(markblee): Support extras.
ENV PIP_FIND_LINKS=https://storage.googleapis.com/jax-releases/jax_cuda_releases.html
RUN pip install .[core,gpu]
COPY . .

################################################################################
# Final target spec.                                                           #
################################################################################

FROM ${TARGET} AS final
