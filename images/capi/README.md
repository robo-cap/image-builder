# Image Builder for Cluster API

The Image Builder can be used to build images intended for use with Kubernetes [CAPI](https://cluster-api.sigs.k8s.io/) providers. Each provider has its own format of images that it can work with. For example, AWS instances use AMIs, and vSphere uses OVAs.

For detailed documentation, see https://image-builder.sigs.k8s.io/capi/capi.html.

## Instructions for OCI

Setup the Python environment:

    sudo dnf install -y python3.12
    python3.12 -m venv py312env
    sed -i 's/false/true/g' py312env/pyvenv.cfg
    source py312env/bin/activate

Install dependencies:

    python3.12 -m pip install --upgrade ansible
    make deps-oci

Ensure packer is installed or the `rc-image-builder/images/capi/.local/bin` is added to `$PATH`.

Build the image:

    PACKER_VAR_FILES=oci.json make build-oci-ubuntu-2204

