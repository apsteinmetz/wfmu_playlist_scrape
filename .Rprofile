# Ensure Git LFS data files are present before running any scripts.
# git lfs pull is a no-op if files are already checked out.
if (nchar(Sys.which("git")) > 0) {
  message("Checking Git LFS files...")
  ret <- system("git lfs pull", ignore.stdout = TRUE)
  if (ret != 0) warning("git lfs pull failed; data files may be LFS pointer stubs.")
}
