// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Grpc.Core;
using Microsoft.Extensions.Logging;
using cartservice.cartstore;
using Hipstershop;

namespace cartservice.services
{
    public class CartService : Hipstershop.CartService.CartServiceBase
    {
        private readonly static Empty Empty = new Empty();
        private readonly ICartStore _cartStore;
        private readonly ILogger<CartService> _logger;

        public CartService(ICartStore cartStore, ILogger<CartService> logger)
        {
            _cartStore = cartStore;
            _logger = logger;
        }

        public async override Task<Empty> AddItem(AddItemRequest request, ServerCallContext context)
        {
            var baseFields = new Dictionary<string, object>
            {
                ["user_id"] = request.UserId,
                ["product_id"] = request.Item?.ProductId,
                ["quantity"] = request.Item?.Quantity
            };

            using (Logging.BeginBusinessScope(_logger, "cart_item_add_requested", "add_to_cart", "cart", "add_to_cart", "success", baseFields))
            {
                _logger.LogInformation("cart add requested");
            }

            try
            {
                await _cartStore.AddItemAsync(request.UserId, request.Item.ProductId, request.Item.Quantity);
                using (Logging.BeginBusinessScope(_logger, "cart_item_added", "add_to_cart", "cart", "add_to_cart", "success", baseFields))
                {
                    _logger.LogInformation("cart item added");
                }
                return Empty;
            }
            catch (Exception ex)
            {
                using (Logging.BeginBusinessScope(_logger, "cart_item_added", "add_to_cart", "cart", "add_to_cart", "failure", baseFields))
                {
                    _logger.LogWarning(ex, "cart item add failed");
                }
                throw;
            }
        }

        public override Task<Cart> GetCart(GetCartRequest request, ServerCallContext context)
        {
            var baseFields = new Dictionary<string, object>
            {
                ["user_id"] = request.UserId
            };

            using (Logging.BeginBusinessScope(_logger, "cart_retrieve_requested", "view_cart", "cart", "view_cart", "success", baseFields))
            {
                _logger.LogInformation("cart retrieve requested");
            }

            return GetCartWithLoggingAsync(request, baseFields);
        }

        public async override Task<Empty> EmptyCart(EmptyCartRequest request, ServerCallContext context)
        {
            var baseFields = new Dictionary<string, object>
            {
                ["user_id"] = request.UserId
            };

            using (Logging.BeginBusinessScope(_logger, "cart_empty_requested", "empty_cart", "cart", "empty_cart", "success", baseFields))
            {
                _logger.LogInformation("cart empty requested");
            }

            try
            {
                await _cartStore.EmptyCartAsync(request.UserId);
                using (Logging.BeginBusinessScope(_logger, "cart_emptied", "empty_cart", "cart", "empty_cart", "success", baseFields))
                {
                    _logger.LogInformation("cart emptied");
                }
                return Empty;
            }
            catch (Exception ex)
            {
                using (Logging.BeginBusinessScope(_logger, "cart_emptied", "empty_cart", "cart", "empty_cart", "failure", baseFields))
                {
                    _logger.LogWarning(ex, "cart empty failed");
                }
                throw;
            }
        }

        private async Task<Cart> GetCartWithLoggingAsync(GetCartRequest request, Dictionary<string, object> baseFields)
        {
            try
            {
                var cart = await _cartStore.GetCartAsync(request.UserId);
                baseFields["cart_size"] = cart.Items.Count;
                using (Logging.BeginBusinessScope(_logger, "cart_retrieved", "view_cart", "cart", "view_cart", "success", baseFields))
                {
                    _logger.LogInformation("cart retrieved");
                }
                return cart;
            }
            catch (Exception ex)
            {
                using (Logging.BeginBusinessScope(_logger, "cart_retrieved", "view_cart", "cart", "view_cart", "failure", baseFields))
                {
                    _logger.LogWarning(ex, "cart retrieve failed");
                }
                throw;
            }
        }
    }
}
