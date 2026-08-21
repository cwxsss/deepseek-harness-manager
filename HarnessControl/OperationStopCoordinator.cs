namespace HarnessControl;

internal static class OperationStopCoordinator
{
    public static async Task RunAfterActiveOperationAsync(SemaphoreSlim operationGate, Func<Task> stopOperation)
    {
        await operationGate.WaitAsync();
        try
        {
            await stopOperation();
        }
        finally
        {
            operationGate.Release();
        }
    }
}
