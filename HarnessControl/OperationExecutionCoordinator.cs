namespace HarnessControl;

internal static class OperationExecutionCoordinator
{
    public static async Task<T> RunWithFinalizerAsync<T>(Func<Task<T>> operation, Func<Task> finalizer)
    {
        try
        {
            return await operation();
        }
        finally
        {
            await finalizer();
        }
    }
}
