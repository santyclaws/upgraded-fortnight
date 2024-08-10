#!/bin/bash

# Define the URL of the notebook
NOTEBOOK_URL="https://raw.githubusercontent.com/santyclaws/upgraded-fortnight/main/sheep.ipynb"

# Define the local path where the notebook will be saved
LOCAL_NOTEBOOK_PATH="/home/ubuntu/my_notebooks/sheep.ipynb"

# Define the path where you want to save the output (optional)
OUTPUT_PATH="/home/ubuntu/my_notebooks/notebook_output.ipynb"

# Create directory if it doesn't exist
mkdir -p /home/ubuntu/my_notebooks/

# Download the notebook
wget -O "$LOCAL_NOTEBOOK_PATH" "$NOTEBOOK_URL"

# Check if the download was successful
if [ $? -eq 0 ]; then
    echo "Notebook downloaded successfully."

    # Execute the notebook using papermill or jupyter nbconvert
    papermill "$LOCAL_NOTEBOOK_PATH" "$OUTPUT_PATH"

    # Or, using jupyter nbconvert (no parameterization)
    # jupyter nbconvert --to notebook --execute "$LOCAL_NOTEBOOK_PATH" --output "$OUTPUT_PATH"

    echo "Notebook executed successfully."
else
    echo "Failed to download the notebook."
    exit 1
fi


