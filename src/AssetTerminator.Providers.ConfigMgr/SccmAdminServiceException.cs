namespace AssetTerminator.Providers.ConfigMgr;

public sealed class SccmAdminServiceException : Exception
{
    public SccmAdminServiceException(string message, bool transient, bool notFound, Exception? innerException = null)
        : base(message, innerException)
    {
        Transient = transient;
        NotFound = notFound;
    }

    public bool Transient { get; }
    public bool NotFound { get; }
}
