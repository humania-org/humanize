# Large Files Detected

You are trying to stop, but some files exceed the **{{MAX_LINES}}-line limit**:
{{LARGE_FILES}}

**Why This Matters**:
- Large files are harder to maintain, review, and understand
- They hinder modular development and code reusability
- They make future changes more error-prone

**Required Actions**:

For **code files**:
1. Split into smaller, modular files (each < {{MAX_LINES}} lines)
2. Ensure functionality remains **strictly unchanged** after splitting
3. Consider using the `code-simplifier` agent to review and optimize the refactored code
4. Maintain clear module boundaries and interfaces

For **documentation files**:
1. Split into logical sections or chapters (each < {{MAX_LINES}} lines)
2. Ensure smooth **cross-references** between split files
3. Maintain **narrative flow** and coherence across files
4. Update any table of contents or navigation structures

After splitting the files, commit the changes and attempt to exit again.
