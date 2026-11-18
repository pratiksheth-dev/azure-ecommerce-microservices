// Built by Pratik Sheth — sample portfolio project.
// Orders API: a small .NET 8 minimal API that owns orders. It validates each
// order line against the Catalog API over HTTP (service-to-service call) and
// snapshots the catalog price at order time.

using System.Net;
using System.Net.Http.Json;

var builder = WebApplication.CreateBuilder(args);

// Typed HttpClient for the Catalog service. The base address comes from
// configuration ("CatalogApi:BaseUrl") — locally it points at the Catalog
// API's port; in Docker Compose / Azure it points at the catalog service.
builder.Services.AddHttpClient("catalog", client =>
{
    var baseUrl = builder.Configuration["CatalogApi:BaseUrl"] ?? "http://localhost:5001";
    client.BaseAddress = new Uri(baseUrl);
    client.Timeout = TimeSpan.FromSeconds(10);
});

var app = builder.Build();

// In-memory order store for the sample. Production: Azure SQL for orders and
// an "order-events" Service Bus message per order (see infra/main.bicep).
var orders = new List<Order>();
var nextOrderId = 1;

app.MapGet("/health", () => Results.Ok(new { status = "healthy", service = "orders-api" }));

app.MapGet("/api/orders", () => Results.Ok(orders));

app.MapGet("/api/orders/{id:int}", (int id) =>
{
    var order = orders.FirstOrDefault(o => o.Id == id);
    return order is null ? Results.NotFound() : Results.Ok(order);
});

app.MapPost("/api/orders", async (
    CreateOrderRequest request,
    IHttpClientFactory httpClientFactory) =>
{
    if (string.IsNullOrWhiteSpace(request.CustomerEmail) || !request.CustomerEmail.Contains('@'))
        return Results.BadRequest(new { detail = "A valid customer email is required." });

    if (request.Quantity <= 0)
        return Results.BadRequest(new { detail = "Quantity must be greater than zero." });

    // Service-to-service call: confirm the product exists and get its price.
    var catalog = httpClientFactory.CreateClient("catalog");
    ProductDto? product;

    try
    {
        var response = await catalog.GetAsync($"/api/products/{request.ProductId}");

        if (response.StatusCode == HttpStatusCode.NotFound)
            return Results.NotFound(new { detail = $"Product {request.ProductId} does not exist." });

        response.EnsureSuccessStatusCode();
        product = await response.Content.ReadFromJsonAsync<ProductDto>();
    }
    catch (HttpRequestException ex)
    {
        // The catalog is a hard dependency for placing an order.
        return Results.Problem(
            detail: $"Catalog service unavailable: {ex.Message}",
            statusCode: StatusCodes.Status502BadGateway);
    }

    if (product is null)
        return Results.Problem("Catalog returned an empty product response.", statusCode: 502);

    var order = new Order(
        Id: nextOrderId++,
        CustomerEmail: request.CustomerEmail,
        ProductId: product.Id,
        ProductName: product.Name,
        UnitPrice: product.Price,
        Quantity: request.Quantity,
        Total: product.Price * request.Quantity,
        Status: "Confirmed",
        CreatedAtUtc: DateTime.UtcNow);

    orders.Add(order);

    return Results.Created($"/api/orders/{order.Id}", order);
});

app.Run();

/// <summary>Product shape returned by the Catalog API.</summary>
public record ProductDto(int Id, string Name, string Sku, decimal Price, int StockQuantity);

/// <summary>Payload for placing an order.</summary>
public record CreateOrderRequest(string CustomerEmail, int ProductId, int Quantity);

/// <summary>A placed order, with the catalog price snapshotted at order time.</summary>
public record Order(
    int Id,
    string CustomerEmail,
    int ProductId,
    string ProductName,
    decimal UnitPrice,
    int Quantity,
    decimal Total,
    string Status,
    DateTime CreatedAtUtc);
