#!/bin/bash

# Check if swiftlint is installed
if ! command -v swiftlint &> /dev/null; then
    echo "SwiftLint not found. Installing via Homebrew..."
    brew install swiftlint
fi

# Run SwiftLint autocorrect
echo "Running SwiftLint autocorrect..."
swiftlint --fix

# Run final SwiftLint check
echo "Running final SwiftLint check..."
swiftlint

echo "Formatting complete!"
