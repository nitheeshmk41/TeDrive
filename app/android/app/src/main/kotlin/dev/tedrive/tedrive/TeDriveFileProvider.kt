package dev.tedrive.tedrive

import androidx.core.content.FileProvider

/**
 * TeDrive's own FileProvider. It is a separate class only so that its
 * manifest entry cannot clash with the FileProviders that plugins declare.
 */
class TeDriveFileProvider : FileProvider()
