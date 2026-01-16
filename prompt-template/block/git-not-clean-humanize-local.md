
**Special Case - .humanize directory detected**:
The `.humanize/` directory is created by humanize:start-rlcr-loop and should NOT be committed.
Please add it to .gitignore:
```bash
echo '.humanize*' >> .gitignore
git add .gitignore
```
